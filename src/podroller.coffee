_u          = require "underscore"
path        = require 'path'
express     = require 'express'
fs          = require "fs"
http        = require "http"
Parser      = require "./mp3"
qs          = require 'qs'
uuid        = require "node-uuid"

debug       = require("debug")("podroller")

module.exports = class Core
    constructor: (@options) ->
        if @options.debug
            (require "debug").enable('podroller')
            debug = require("debug")("podroller")
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
        @app.use (req, res, next) => @podRouter(req, res, next)
        @server = @app.listen @options.port
        debug "Listening on port #{ @options.port }"

        # -- set up a shutdown handler -- #

        process.on "SIGTERM", =>
            # stop listening
            @server.close()

            # now start polling to see how many files we're delivering
            # when should we get pushy?
            @_shutdownMaxTime = (new Date).getTime() + @options.max_zombie_life

            console.error "Got SIGTERM. Starting graceful shutdown with #{@listeners} listeners."

            # need to start a process to quit when existing connections disconnect
            @_shutdownTimeout = setInterval =>
                # have we used up the grace period yet?
                force_shut = if (new Date).getTime() > @_shutdownMaxTime then true else false

                if @listeners == 0 || force_shut
                    # everyone's out...  go ahead and shut down
                    console.error "Shutdown complete"
                    process.exit()
                else
                    console.error "Still awaiting shutdown; #{@listeners} listeners"
            , 60 * 1000

    #----------

    podRouter: (req, res, next) ->
        # if we take prefix away from req.url, does it match an audio file?
        match = ///^#{@options.prefix}(.*)///.exec req.path

        if !match?[1]
            next()
            return false

        req.count = @_counter++

        filename = path.join(@options.audio_dir, match[1])
        fs.stat filename, (err, stats) =>
            # if there was a stat error or this isn't a file, move on
            if err || !stats.isFile()
                next()
                return true

            # -- Do they have a uuid? -- #

            if @options.redirect_url && !req.param('uuid')
                id = uuid.v4()
                debug "#{req.count}: Redirecting with UUID of #{ id }"
                url = "#{ @options.redirect_url }#{ req.originalUrl.replace('//','/') }" + (if Object.keys(req.query).length > 0 then "&uuid=#{id}" else "?uuid=#{id}")
                res.redirect 302, url

            else
                debug "#{req.count}: Request UUID is #{ req.param('uuid') }"
                # is this a file we already know about?
                # if so, has it not been changed?
                if @key_cache[filename] &&
                @key_cache[filename]?.mtime == stats.mtime.getTime() &&
                @key_cache[filename].stream_key
                    # we're good.  use the cached stream key
                    # for preroll, then send our file
                    @streamPodcast req, res, @key_cache[filename]
                else
                    # never seen this one, or it's changed since we saw it
                    # -- validate it and get its audio settings -- #

                    mtime = stats.mtime.getTime()

                    # look for ID3 tag
                    # we do this by streaming the file into our parser,
                    # and seeing which comes first: an ID3 tag or an
                    # mp3 header.  Once we hit first audio, we assume
                    # no tag and move on.  we cache any tag we get to
                    # deliver at the head of the combined file
                    @checkForID3 filename, (stream_key,id3) =>
                        k = @key_cache[filename] =
                            filename:   filename
                            mtime:      mtime
                            stream_key: stream_key
                            id3:        id3
                            size:       stats.size

                        @streamPodcast(req, res, k)

    #----------

    checkForID3: (filename, cb) =>
        parser = new Parser

        tags = []

        parser.on "debug", (msgs...) =>
            debug msgs...

        parser.once "id3v2", (buf) =>
            # got an ID3v2
            debug "got an id3v2 of ", buf.length
            tags.push buf

        parser.once "id3v1", (buf) =>
            # got an ID3v1
            debug "got an id3v1 of ", buf.length
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

            debug "tag_buf is ", tag_buf
            debug "stream_key is ", h.stream_key

            cb h.stream_key, tag_buf

        rstream = fs.createReadStream filename
        rstream.pipe parser

    #----------

    streamPodcast: (req, res, k) ->
        return false if req.connection.destroyed

        # Check if this is a range request
        # False by default
        rangeRequest = false

        if _u.isString(req.headers.range)
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

        @loadPreroll k.stream_key, req, (predata = null) =>
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

            req.connection.on "close", =>
                debug "#{req.count}: (conn close) in close. #{@listeners} active downloads."
                @listeners--

            req.connection.setTimeout 30*1000, =>
                # handle connection timeout
                res.end()
                rstream?.destroy() if rstream?.readable

    #----------

    loadPreroll: (key, req, cb) ->
        count = req.count

        cb = _u.once cb

        # short-circuit if we're missing any options
        debug "#{count}: preroller opts is ", @options.preroll, key
        unless @options.preroll?.server &&
        @options.preroll?.key &&
        @options.preroll?.path
            cb?()
            return true

        # Pass along any query string to Preroller
        query = qs.stringify(req.query)

        aborted = false

        opts =
            host: @options.preroll.server
            path: [
                @options.preroll.path,
                @options.preroll.key,
                key, "?" + query
            ].join("/")

        conn = req.connection

        # refuse to wait longer than 250ms
        req_t = setTimeout =>
            debug "#{count}: Preroll timeout reached."
            conn_pre_abort()
            cb()
        , 750

        debug "firing preroll request", count
        req = http.get opts, (rres) =>
            debug "#{count}: got preroll response ", rres.statusCode
            if rres.statusCode == 200
                # collect preroll and return it so length can be computed

                # FIXME: If our preroll host was sending us a content-length
                # header, we could return that with the res stream, so that
                # we could stream the preroll straight through to the client

                buffers = []
                buf_len = 0

                clearTimeout req_t

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
