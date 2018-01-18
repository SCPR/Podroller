_           = require "underscore"
path        = require 'path'
express     = require 'express'
fs          = require "fs"
http        = require "http"
https       = require "https"
Parser      = (require "sm-parsers").MP3
qs          = require 'qs'
uuid        = require "node-uuid"
ua          = require 'universal-analytics'
debug       = require("debug")("podroller")

module.exports = class Core
    constructor: (@options) ->
        debug "Debug logging is enabled"

        # -- make sure our audio dir is valid -- #

        debug "Audio dir is #{ @options.audio_dir }"
        if !fs.existsSync(@options.audio_dir)
            console.error "Audio path is invalid!"
            process.exit()

        # -- set up cache storage -- #
        @key_cache  = {}
        @listeners  = 0
        @_counter   = 0

        # -- set up a server -- #
        @app = express()

        if Object.keys(@options.prefixes).length > 0
            for p,opts of @options.prefixes
                papp = @_createApp(p,opts)
                @app.use p, papp
                debug "Registered app handler for #{p}"

        else
            prefix = @options.prefix||"/"
            papp = @_createApp(prefix,preroll_key:@options.preroll?.key)
            @app.use prefix

        @server = http.createServer(@app)
        @server.listen @options.port
        #@server = @app.listen @options.port
        debug "Listening on port #{ @options.port }"

    #----------

    _createApp: (prefix,opts) ->
        _app = express()

        _app.use (req,res,next) =>
            req.podroller_prefix = prefix
            next()

        _app.use @onlyValidFiles()
        _app.use @injectUUID() if @options.redirect_url
        _app.use @requestHandler(opts)

        _app

    #----------

    onlyValidFiles: ->
        (req,res,next) =>
            req.count = @_counter++

            filename = path.join(@options.audio_dir, req.path)

            debug "#{req.count}:#{req.podroller_prefix}: Path is #{req.path}"

            fs.stat filename, (err, stats) =>
                # if there was a stat error or this isn't a file, return a 404
                if err || !stats.isFile()
                    res.status(404).end()
                else
                    req.filename    = filename
                    req.fstats      = stats
                    next()

    #----------

    injectUUID: ->
        (req,res,next) =>
            if !req.query.uuid
                id = uuid.v4()
                debug "#{req.count}:#{req.podroller_prefix}: Redirecting with UUID of #{ id } (#{req.originalUrl})"
                url = "#{ @options.redirect_url }#{ req.originalUrl.replace('//','/') }" + (if Object.keys(req.query).length > 0 then "&uuid=#{id}" else "?uuid=#{id}")
                res.redirect 302, url
            else
                next()

    #----------

    requestHandler: (opts) ->
        (req, res, next) =>
            debug "#{req.count}:#{req.podroller_prefix}: Request UUID is #{ req.query.uuid }"
            # is this a file we already know about?
            # if so, has it not been changed?
            if @key_cache[req.filename] &&
            @key_cache[req.filename]?.mtime == req.fstats.mtime.getTime() &&
            @key_cache[req.filename].stream_key
                # we're good.  use the cached stream key
                # for preroll, then send our file
                @streamPodcast req, res, @key_cache[req.filename], opts.preroll_key
            else
                # never seen this one, or it's changed since we saw it
                # -- validate it and get its audio settings -- #

                mtime = req.fstats.mtime.getTime()

                # look for ID3 tag
                # we do this by streaming the file into our parser,
                # and seeing which comes first: an ID3 tag or an
                # mp3 header.  Once we hit first audio, we assume
                # no tag and move on.  we cache any tag we get to
                # deliver at the head of the combined file
                @checkForID3 req.filename, (stream_key,id3) =>
                    k = @key_cache[req.filename] =
                        filename:   req.filename
                        mtime:      mtime
                        stream_key: stream_key
                        id3:        id3
                        size:       req.fstats.size

                    @streamPodcast req, res, k, opts.preroll_key

    #----------

    checkForID3: (filename, cb) =>
        parser = new Parser

        tags = []

        parser.on "debug", (msgs...) =>
            #debug msgs...

        parser.once "id3v2", (buf) =>
            # got an ID3v2
            #debug "got an id3v2 of ", buf.length
            tags.push buf

        parser.once "id3v1", (buf) =>
            # got an ID3v1
            #debug "got an id3v1 of ", buf.length
            tags.push buf

        parser.once "frame", (buf,h) =>
            rstream.unpipe()
            parser.end()
            rstream.destroy()

            # got a frame... grab the stream key

            tag_buf = switch
                when tags.length == 0
                    null
                when tags.length == 1
                    tags[0]
                else
                    Buffer.concat(tags)

            debug "tag_buf is #{tag_buf}"
            debug "stream_key is #{h.stream_key}"

            cb h.stream_key, tag_buf

        rstream = fs.createReadStream filename
        rstream.pipe parser

    #----------

    streamPodcast: (req, res, k, preroll_key) ->
        return false if req.connection.destroyed
        # Check if this is a range request
        # False by default
        rangeRequest = false
        if _.isString(req.headers.range)
            rangeVals    = req.headers.range.match(/^bytes ?= ?(\d+)?-(\d+)?$/)

            if rangeVals
                rangeRequest = true

                # Get the requested start and end
                # Force into integers
                requestStart    = if rangeVals[1]? then rangeVals[1] - 0 else undefined
                requestEnd      = if rangeVals[2]? then rangeVals[2] - 0 else undefined

                if requestStart && requestEnd && (requestStart > requestEnd)
                    res.writeHead 416, "Content-type":"text/html"
                    res.end "416 Requested Range Not Valid"
                    return false

            else
                console.log "Invalid range header? #{ req.headers.range }"
                res.writeHead 416, "Content-type":"text/html"
                res.end "416 Requested Range Not Valid"
                return false

        @loadPreroll k.stream_key, req, preroll_key, (predata = null) =>
            if req.connection.destroyed
                # we died enroute
                debug "Request was aborted."
                return false

            # compute our final size
            # If this isn't a range request, then this info won't
            # be changed.
            # If it IS a range request, then "length" will get
            # changed to be the chunk size.

            fsize   = (predata?.length||0) + k.size
            fend    = fsize - 1
            length  = fsize

            debug req.method, req.url
            debug "#{req.count}: size:", fsize
            debug "#{req.count}: Preroll data length is : #{ predata?.length || 0}"

            @listeners++

            rangeStart  = 0
            rangeEnd    = fend

            if rangeRequest
                # short-circuit with a 416 if the range start is too big
                if requestStart? && requestStart > fend
                    headers =
                        "Content-Type":         "text/plain"

                    res.writeHead 416, headers
                    res.end "416 Requested Range Not Satisfiable"

                    return false

                if requestStart? && !requestEnd?
                    rangeStart  = requestStart
                    rangeEnd    = fend

                else if requestEnd? && !requestStart?
                    rangeStart  = fend - requestEnd
                    rangeEnd    = fend

                else
                    rangeStart  = requestStart
                    rangeEnd    = if requestEnd < fend then requestEnd else fend

                length = (rangeEnd - rangeStart) + 1

            # send out headers
            headers =
                "Content-Type"      : "audio/mpeg",
                "Connection"        : "close",
                "Transfer-Encoding" : "identity",
                "Content-Length"    : length,
                "Accept-Ranges"     : "bytes"

            if rangeRequest
                headers["Cache-Control"] = "no-cache"
                headers["Content-Range"] = "bytes #{rangeStart}-#{rangeEnd}/#{fsize}"
                res.writeHead 206, headers
            else
                res.writeHead 200, headers

            debug "#{req.count}: response headers are", headers

            # If this is a HEAD request, we don't need to
            # pipe the actual data to the client, so
            # after setting all the headers, we're done.
            if req.method == "HEAD"
                res.end()
                return true


            # now set up our file read as a stream
            debug "#{req.count}: creating read stream. #{@listeners} active downloads."

            # -- deliver content -- #

            # What we deliver is a little complicated. If this is a normal request,
            # we deliver 1) ID3, 2) Preroll, 3) original file, minus the original ID3.

            # If it's a range request, we could deliver a chunk that contains any or
            # all of those.

            prerollStart    = k.id3?.length || 0
            prerollEnd      = prerollStart + (predata?.length || 0)
            fileStart       = prerollEnd

            _decListener = _.once =>
                @listeners--

            # write id3?
            if k.id3? && rangeStart < k.id3.length
                debug "#{req.count}: Writing id3 of ", k.id3.length, rangeStart, rangeEnd
                res.write k.id3.slice(rangeStart,rangeEnd+1)

            if predata? && ( ( rangeStart <= prerollStart < rangeEnd ) || ( rangeStart <= prerollEnd < rangeEnd ) )
                pstart = rangeStart - prerollStart
                pstart = 0 if pstart < 0

                debug "#{req.count}: Writing preroll: ", pstart, rangeEnd - prerollEnd + 1
                res.write predata.slice( pstart, rangeEnd - prerollEnd + 1 )

            rstream = null
            if rangeEnd > fileStart
                fstart = rangeStart - fileStart
                fstart = 0 if fstart < 0

                fend = rangeEnd - fileStart + 1

                if k.id3?.length
                    fstart += k.id3.length
                    fend += k.id3.length

                readStreamOpts =
                    bufferSize:     256*1024
                    start:          fstart
                    end:            fend

                debug "#{req.count}: read stream opts are", readStreamOpts
                rstream = fs.createReadStream k.filename, readStreamOpts
                rstream.pipe res, end: false
                @triggerGAEvent(req, preroll_key, k.filename)

                rstream.on "end", =>
                    # got to the end of the file.  close our response
                    debug "#{req.count}: (stream end) wrote #{ res.socket?.bytesWritten } bytes. #{@listeners} active downloads."
                    res.end()
                    rstream.destroy()

            else
                res.end()

            req.connection.on "end", =>
                # connection aborted.  destroy our stream
                debug "#{req.count}: (connection end) wrote #{ res.socket?.bytesWritten } bytes. #{@listeners} active downloads."
                rstream?.destroy() if rstream?.readable
                _decListener()


            req.connection.on "close", =>
                debug "#{req.count}: (conn close) in close. #{@listeners} active downloads."
                rstream?.destroy() if rstream?.readable
                _decListener()

            req.connection.setTimeout 30*1000, =>
                # handle connection timeout
                debug "#{req.count}: Connection timeout. Ending."
                res.end()
                rstream?.destroy() if rstream?.readable
                _decListener()

#----------
    triggerGAEvent: (req, preroll_key, filename) ->
        if !@options.google_analytics
            return
        gaId = @options.google_analytics.property
        if !gaId
            return
        reqUuid = @isRealDownloadAndReturnsUuid(req)
        if preroll_key == 'podcast' && reqUuid
            visitor = ua(gaId)
            eventProperties = {
                ec: "Podcast",
                ea: "Download",
                el: filename
            }
            if @options.google_analytics.custom_dimension
                eventProperties[@options.google_analytics.custom_dimension] = reqUuid
            visitor.event(eventProperties).send()

#----------
    isRealDownloadAndReturnsUuid: (req) ->
        if req.headers['user-agent'] && req.headers['user-agent'].match(/bot/i)
            return false
        if !req.query || !req.query.uuid
            return false
        return req.query.uuid
#----------

    loadPreroll: (stream_key, req, preroll_key, cb) ->
        count = req.count

        cb = _.once cb

        # short-circuit if we're missing any options
        unless @options.preroll?.server &&
        preroll_key &&
        @options.preroll?.path
            cb?()
            return true

        # Pass along any query string to Preroller
        query = qs.stringify(req.query)

        aborted = false

        opts =
            host: @options.preroll.server
            port: @options.preroll.port || 80
            path: [
                @options.preroll.path,
                preroll_key,
                stream_key, "?" + query
            ].join("/")

        conn = req.connection

        # refuse to wait longer than 250ms
        req_t = setTimeout =>
            debug "#{count}: Preroll timeout reached."
            conn_pre_abort()
            cb()
        , 750

        debug "Firing preroll request", count, opts
        req = https.get opts, (rres) =>
            debug "#{count}: got preroll response ", rres.statusCode

            # clear our abort timer
            clearTimeout req_t

            if rres.statusCode == 200
                # collect preroll and return it so length can be computed

                # FIXME: If our preroll host was sending us a content-length
                # header, we could return that with the res stream, so that
                # we could stream the preroll straight through to the client

                buffers = []
                buf_len = 0

                rres.on "readable", =>
                    while chunk = rres.read()
                        buffers.push chunk
                        buf_len += chunk.length

                # when preroll is done, call the output's callback
                rres.on "end", =>
                    conn.removeListener "close", conn_pre_abort
                    conn.removeListener "end", conn_pre_abort

                    pre_data = Buffer.concat buffers, buf_len

                    cb(pre_data)
                    return true

            else
                conn.removeListener "close", conn_pre_abort
                conn.removeListener "end", conn_pre_abort
                cb()
                return true

        req.on "socket", (sock) =>
            debug "#{count}: preroll socket granted"

        req.on "error", (err) =>
            debug "#{count}: got a request error.", err
            conn.removeListener "close", conn_pre_abort
            conn.removeListener "end", conn_pre_abort

            clearTimeout req_t if req_t

            cb()
            return true

        # attach a close listener to the response, to be fired if it gets
        # shut down and we should abort the request

        conn_pre_abort = =>
            debug "#{count}: conn_pre_abort called. Destroyed? ", conn.destroyed

            if !aborted
                debug "#{count}: Aborting preroll"
                req.abort()
                aborted = true

            clearTimeout req_t

        # we don't need to fire the callback after these
        conn.once "close", conn_pre_abort
        conn.once "end", conn_pre_abort

