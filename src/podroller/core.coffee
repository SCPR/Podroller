_u          = require "underscore"
path        = require 'path'
express     = require 'express'
fs          = require "fs"
ffmpegmeta  = require('fluent-ffmpeg').Metadata
http        = require "http"
Parser      = require "./mp3parser"
qs          = require 'qs'

module.exports = class Core
    DefaultOptions:
        log: null
        port: 8000
        prefix: ""
        # after a new deployment, allow a 30 minute grace period for 
        # connected listeners to finish their downloads
        max_zombie_life: 2 * 60 * 1000



    constructor: (opts={}) ->
        @options = _u.defaults opts, @DefaultOptions

        # -- make sure our audio dir is valid -- #
        if !path.existsSync(@options.audio_dir)
            console.error "Audio path is invalid!"
            process.exit()

        # -- set up cache storage -- #
        @key_cache  = {}
        @listeners  = 0
        @_counter   = 0

        # -- set up a server -- #
        console.debug "config is ", @options
        @app = express()
        @app.use (req, res, next) => @podRouter(req, res, next)
        @server = @app.listen @options.port

        # -- set up a shutdown handler -- #

        process.on "SIGTERM", =>
            # stop listening 
            @server.close()

            # now start polling to see how many files we're delivering
            # when should we get pushy?
            @_shutdownMaxTime = (new Date).getTime() + @options.max_zombie_life

            console.log "Got SIGTERM. Starting graceful shutdown with #{@listeners} listeners."

            # need to start a process to quit when existing connections disconnect
            @_shutdownTimeout = setInterval =>
                # have we used up the grace period yet?
                force_shut = if (new Date).getTime() > @_shutdownMaxTime then true else false

                if @listeners == 0 || force_shut
                    # everyone's out...  go ahead and shut down
                    console.log "Shutdown complete"
                    process.exit()
                else
                    console.log "Still awaiting shutdown; #{@listeners} listeners"
            , 60 * 1000



    podRouter: (req, res, next) ->
        # if we take prefix away from req.url, does it match an audio file?
        match = ///^#{@options.prefix}(.*)///.exec req.path

        return false if !match?[1]

        filename = path.join(@options.audio_dir, match[1]) 
        fs.stat filename, (err, stats) =>
            # if there was a stat error or this isn't a file, move on 
            if err || !stats.isFile()
                next()
                return true

            # is this a file we already know about?
            # if so, has it not been changed?
            if @key_cache[filename] &&
            @key_cache[filename]?.mtime == stats.mtime.getTime() &&
            @key_cache[filename].stream_key
                # we're good.  use the cached stream key 
                # for preroll, then send our file
                @streamPodcast req, res, filename, stats.size,
                    @key_cache[filename].stream_key,
                    @key_cache[filename].id3
            else
                # never seen this one, or it's changed since we saw it
                # -- validate it and get its audio settings -- #
                new ffmpegmeta filename, (meta, err) =>
                    if !meta
                        @res.writeHead 404,
                            "Content-Type": "text/plain",
                            "Connection"  : "close"

                        @res.end("File not found.")
                        return false

                    # stash our stream key and mtime
                    key = [
                        meta.audio.codec,
                        meta.audio.sample_rate,
                        meta.audio.bitrate,
                        if meta.audio.channels == 2 then "s" else "m"
                    ].join("-")

                    mtime = stats.mtime.getTime()

                    # look for ID3 tag
                    # we do this by streaming the file into our parser, 
                    # and seeing which comes first: an ID3 tag or an 
                    # mp3 header.  Once we hit first audio, we assume 
                    # no tag and move on.  we cache any tag we get to 
                    # deliver at the head of the combined file
                    @checkForID3 filename, (id3) =>
                        @key_cache[filename] =
                            mtime      : mtime
                            stream_key : key
                            id3        : id3

                        @streamPodcast(req, res, filename, stats.size, key, id3)



    checkForID3: (filename, cb) =>
        parser = new Parser(true)

        cb = _u.once(cb) if cb

        parser.on "id3v2", (buf) =>
            # got an ID3
            cb?(buf)

        parser.on "header", (h, buf) =>
            # got a frame
            cb?()

        # we only read the first 4k
        rstream = fs.createReadStream filename,
            bufferSize : 256*1024
            start      : 0
            end        : 4096

        rstream.pipe parser, end: false
        rstream.on "end", => parser.end()



    streamPodcast: (req, res, filename, size, stream_key, id3) ->
        return false if req.connection.destroyed

        # Check if this is a range request
        # False by default
        rangeRequest = false

        if _u.isString(req.headers.range)
            rangeVals    = req.headers.range.match(/bytes ?= ?(\d+)-(\d+)?/)
            rangeRequest = true


        @loadPreroll stream_key, req, (predata = null) =>
            # compute our final size
            # If this isn't a range request, then this info won't
            # be changed.
            # If it IS a range request, then "length" will get
            # changed to be the chunk size.
            fsize   = (id3?.length||0) + (predata?.length||0) + size
            fend    = fsize - 1
            length  = fsize

            console.debug req.method, req.url
            console.debug "size:", fsize

            @listeners++

            if rangeRequest
                # Get the requested start and end
                # Force into integers
                requestStart    = rangeVals[1] - 0
                requestEnd      = rangeVals[2] - 0 or undefined

                rangeStart  = if (requestStart  <= fend) then requestStart else 0
                rangeEnd    = if (requestEnd    <= fend) then requestEnd   else fend
                
                length = (rangeEnd - rangeStart) + 1

            # What is the actual length of content being sent back?
            console.debug "actual length is", length

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

            console.debug "response headers are", headers

            # If this is a HEAD request, we don't need to 
            # pipe the actual data to the client, so
            # after setting all the headers, we're done.
            if req.method == "HEAD"
                res.end()
                return true


            # if we have an id3 or preroll, write them
            res.write id3 if id3
            res.write predata if predata


            # now set up our file read as a stream
            console.debug "creating read stream. #{@listeners} active downloads."
            readStreamOpts = bufferSize: 256*1024

            # If this is a range request, only deliver that range of bytes
            if rangeRequest
                console.debug "Sending byte range #{rangeStart}-#{rangeEnd}"
                readStreamOpts['start'] = rangeStart
                readStreamOpts['end']   = rangeEnd

            console.debug "read stream opts are", readStreamOpts
            rstream = fs.createReadStream filename, readStreamOpts
            rstream.pipe res, end: false

            rstream.on "end", => 
                # got to the end of the file.  close our response
                console.debug "(stream end) wrote #{ res.socket?.bytesWritten } bytes. #{@listeners} active downloads."
                res.end()

            req.connection.on "end", =>
                # connection aborted.  destroy our stream
                console.debug "(connection end) wrote #{ res.socket?.bytesWritten } bytes. #{@listeners} active downloads."
                rstream?.destroy() if rstream?.readable

            req.connection.on "close", => 
                console.debug "(conn close) in close. #{@listeners} active downloads."
                @listeners--

            req.connection.setTimeout 30*1000, =>
                # handle connection timeout
                res.end()
                rstream?.destroy() if rstream?.readable



    loadPreroll: (key, req, cb) ->
        count = @_counter++

        # short-circuit if we're missing any options
        console.debug "preroller opts is ", @options.preroll, key
        unless @options.preroll?.server &&
        @options.preroll?.key &&
        @options.preroll?.path
            cb?()
            return true

        # Pass along any query string to Preroller
        query = qs.stringify(req.query)

        opts = 
            host: @options.preroll.server
            path: [
                @options.preroll.path,
                @options.preroll.key,
                key, "?" + query
            ].join("/")

        conn = req.connection

        console.debug "firing preroll request", count
        req = http.get opts, (rres) =>
            console.debug "got preroll response ", count
            if rres.statusCode == 200
                # collect preroll and return it so length can be computed
                pre_data = new Buffer(0)

                rres.on "data", (chunk) =>
                    buf = new Buffer(pre_data.length + chunk.length)
                    pre_data.copy(buf, 0)
                    chunk.copy(buf, pre_data.length)
                    pre_data = buf

                # when preroll is done, call the output's callback
                rres.on "end", =>
                    conn.removeListener "close", conn_pre_abort
                    conn.removeListener "end", conn_pre_abort
                    cb?(pre_data)
                    return true

            else
                conn.removeListener "close", conn_pre_abort
                conn.removeListener "end", conn_pre_abort
                cb?()
                return true

        req.on "socket", (sock) =>
            console.debug "socket granted for ", count

        req.on "error", (err) =>
            console.debug "got a request error for ", count, err

        # attach a close listener to the response, to be fired if it gets 
        # shut down and we should abort the request

        conn_pre_abort = => 
            if conn.destroyed
                console.debug "aborting preroll ", count
                req.abort()

        conn.once "close", conn_pre_abort
        conn.once "end", conn_pre_abort
