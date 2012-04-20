_u = require "underscore"
path = require 'path'
express = require 'express'
fs = require "fs"
ffmpegmeta = require('fluent-ffmpeg').Metadata
http = require "http"
Parser = require "./mp3parser"

module.exports = class Core
    DefaultOptions:
        log:    null
        port:   8000
        prefix: ""
        
    constructor: (opts) ->
        @options = _u.defaults opts||{}, @DefaultOptions
        
        # -- make sure our audio dir is valid -- #
        
        if !path.existsSync(@options.audio_dir)
            console.error "Audio path is invalid!"
            process.exit()
            
        # -- set up cache storage -- #
        
        @key_cache = {}
        
        # -- set up a server -- #
        
        console.log "config is ", @options
        
        @server = express.createServer()
        @server.use (req,res,next) => @podRouter(req,res,next)
        @server.listen @options.port
        
    #----------
    
    podRouter: (req,res,next) ->
        # if we take prefix away from req.url, does it match an audio file?
        match = ///^#{@options.prefix}(.*)///.exec req.url
        
        if match?[1]
            filename = path.join(@options.audio_dir,match[1]) 
            fs.stat filename, (err,stats) =>
                # if there was a stat error or this isn't a file, move on 
                if err || !stats.isFile()
                    next()
                    return true
                
                # is this a file we already know about? if so, has it not been changed?
                if @key_cache[ filename ] && @key_cache[filename]?.mtime == stats.mtime.getTime() && @key_cache[filename].stream_key
                    # we're good.  use the cached stream key for preroll, then send our file
                    @streamPodcast req, res, filename, stats.size, @key_cache[filename].stream_key, @key_cache[filename].id3
                else
                    # never seen this one, or it's changed since we saw it
                    
                    # -- validate it and get its audio settings -- #
                    ffmpegmeta.get filename, (meta) =>
                        if meta
                            # stash our stream key and mtime
                            key = [meta.audio.codec,meta.audio.sample_rate,meta.audio.bitrate,(if meta.audio.channels == 2 then "s" else "m")].join("-")
                            mtime = stats.mtime.getTime()

                            # -- now look for ID3 tag -- #
                            
                            # we do this by streaming the file into our parser, 
                            # and seeing which comes first: an ID3 tag or an 
                            # mp3 header.  Once we hit first audio, we assume 
                            # no tag and move on.  we cache any tag we get to 
                            # deliver at the head of the combined file
                            
                            @checkForID3 filename, (id3) =>
                                @key_cache[ filename ] = mtime:mtime, stream_key:key, id3:id3
                                @streamPodcast req, res, filename, stats.size, key, id3
                        else
                            @res.writeHead 404, "Content-Type":"text/plain", "Connection":"close"
                            @res.end("File not found.")
                            
    #----------
    
    checkForID3: (filename,cb) =>
        parser = new Parser(true)
        
        cb = _u.once(cb) if cb
        
        parser.on "id3v2", (buf) =>
            # got an ID3
            console.log "check got an ID3!", buf
            #rstream.destroy()
            cb?(buf)
            
        parser.on "header", (h,buf) =>
            # got a frame
            console.log "check got a header!"
            #rstream.destroy()
            cb?()
            
        # we only read the first 4k
        rstream = fs.createReadStream filename, bufferSize:256*1024, start:0, end:4096
        rstream.pipe parser, end:false
        
        rstream.on "end", => parser.end()
    
    #----------
    
    streamPodcast: (req,res,filename,size,stream_key,id3) ->
        @loadPreroll stream_key, (predata = null) =>
            # compute our final size
            fsize = (id3?.length||0) + (predata?.length||0) + size
            
            console.log "id3 length is ", id3.length
            
            # send out headers
            headers = 
                "Content-Type":         "audio/mpeg",
                "Connection":           "close",
                "Transfer-Encoding":    "identity",
                "Content-Length":       fsize
                
            console.log "final size should be ", fsize
                
            res.writeHead 200, headers
            
            # if we have an id3, write that
            res.write id3 if id3
                                
            # write the preroll
            res.write predata if predata
            
            # now set up our file read as a stream
            console.log "creating read stream"
            rstream = fs.createReadStream filename, bufferSize:256*1024

            rstream.pipe res, end:false
                            
            rstream.on "end", => 
                # got to the end of the file.  close our response
                console.log "wrote #{ res.socket?.bytesWritten } bytes"
                res.end()
            
            req.connection.on "end", =>
                # connection aborted.  destroy our stream
                console.log "wrote #{ res.socket?.bytesWritten } bytes"
                rstream?.destroy()
            
    #----------
    
    loadPreroll: (key,cb) ->
        # short-circuit if we're missing any options
        console.log "preroller opts is ", @options.preroll
        unless @options.preroll?.server && @options.preroll?.key && @options.preroll?.path
            cb?()
            return true
        
        # -- make a request to the preroll server -- #
        
        console.log "making a preroll request"
        
        opts = 
            host:       @options.preroll.server
            path:       [@options.preroll.path,@options.preroll.key,key].join("/")
        
        req = http.get opts, (rres) =>
            if rres.statusCode == 200
                # collect preroll data and then return it
                pre_data = new Buffer(0)
                rres.on "data", (chunk) => 
                    buf = new Buffer(pre_data.length + chunk.length)
                    pre_data.copy(buf,0)
                    chunk.copy(buf,pre_data.length)
                    pre_data = buf

                # when preroll is done, call the output's callback
                rres.on "end", =>
                    console.log "calling podcast callback with preroll data of ", pre_data.length
                    cb?(pre_data)
                    return true
            else
                cb?()
                return true
        
                            
        