var Core, Parser, express, fs, http, path, qs, uuid, _u,
  __bind = function(fn, me){ return function(){ return fn.apply(me, arguments); }; },
  __slice = [].slice;

_u = require("underscore");

path = require('path');

express = require('express');

fs = require("fs");

http = require("http");

Parser = require("./mp3");

qs = require('qs');

uuid = require("node-uuid");

module.exports = Core = (function() {
  Core.prototype.DefaultOptions = {
    log: null,
    port: 8000,
    prefix: "",
    max_zombie_life: 2 * 60 * 1000
  };

  function Core(opts) {
    if (opts == null) {
      opts = {};
    }
    this.checkForID3 = __bind(this.checkForID3, this);
    this.options = _u.defaults(opts, this.DefaultOptions);
    if (!path.existsSync(this.options.audio_dir)) {
      console.error("Audio path is invalid!");
      process.exit();
    }
    this.key_cache = {};
    this.listeners = 0;
    this._counter = 0;
    console.debug("config is ", this.options);
    this.app = express();
    this.app.use((function(_this) {
      return function(req, res, next) {
        return _this.podRouter(req, res, next);
      };
    })(this));
    this.server = this.app.listen(this.options.port);
    process.on("SIGTERM", (function(_this) {
      return function() {
        _this.server.close();
        _this._shutdownMaxTime = (new Date).getTime() + _this.options.max_zombie_life;
        console.log("Got SIGTERM. Starting graceful shutdown with " + _this.listeners + " listeners.");
        return _this._shutdownTimeout = setInterval(function() {
          var force_shut;
          force_shut = (new Date).getTime() > _this._shutdownMaxTime ? true : false;
          if (_this.listeners === 0 || force_shut) {
            console.log("Shutdown complete");
            return process.exit();
          } else {
            return console.log("Still awaiting shutdown; " + _this.listeners + " listeners");
          }
        }, 60 * 1000);
      };
    })(this));
  }

  Core.prototype.podRouter = function(req, res, next) {
    var filename, match;
    match = RegExp("^" + this.options.prefix + "(.*)").exec(req.path);
    if (!(match != null ? match[1] : void 0)) {
      next();
      return false;
    }
    filename = path.join(this.options.audio_dir, match[1]);
    return fs.stat(filename, (function(_this) {
      return function(err, stats) {
        var id, mtime, url, _ref;
        if (err || !stats.isFile()) {
          next();
          return true;
        }
        if (!req.param('uuid')) {
          id = uuid.v4();
          console.debug("Redirecting with UUID of " + id);
          url = ("" + _this.options.redirect_url + (req.originalUrl.replace('//', '/'))) + (Object.keys(req.query).length > 0 ? "&uuid=" + id : "?uuid=" + id);
          return res.redirect(302, url);
        } else {
          console.debug("Request UUID is " + (req.param('uuid')));
          if (_this.key_cache[filename] && ((_ref = _this.key_cache[filename]) != null ? _ref.mtime : void 0) === stats.mtime.getTime() && _this.key_cache[filename].stream_key) {
            return _this.streamPodcast(req, res, _this.key_cache[filename]);
          } else {
            mtime = stats.mtime.getTime();
            return _this.checkForID3(filename, function(stream_key, id3) {
              var k;
              k = _this.key_cache[filename] = {
                filename: filename,
                mtime: mtime,
                stream_key: stream_key,
                id3: id3,
                size: stats.size
              };
              return _this.streamPodcast(req, res, k);
            });
          }
        }
      };
    })(this));
  };

  Core.prototype.checkForID3 = function(filename, cb) {
    var parser, rstream, tags;
    parser = new Parser;
    tags = [];
    parser.on("debug", (function(_this) {
      return function() {
        var msgs;
        msgs = 1 <= arguments.length ? __slice.call(arguments, 0) : [];
        return console.debug.apply(console, msgs);
      };
    })(this));
    parser.once("id3v2", (function(_this) {
      return function(buf) {
        console.debug("got an id3v2 of ", buf.length);
        return tags.push(buf);
      };
    })(this));
    parser.once("id3v1", (function(_this) {
      return function(buf) {
        console.debug("got an id3v1 of ", buf.length);
        return tags.push(buf);
      };
    })(this));
    parser.once("frame", (function(_this) {
      return function(buf, h) {
        var tag_buf;
        rstream.unpipe();
        parser.end();
        rstream.destroy();
        tag_buf = (function() {
          switch (false) {
            case tags.length !== 0:
              return null;
            case tags.length !== 1:
              return tags[0];
            default:
              return Buffer.concat(tags);
          }
        })();
        console.debug("tag_buf is ", tag_buf);
        console.debug("stream_key is ", h.stream_key);
        return cb(h.stream_key, tag_buf);
      };
    })(this));
    rstream = fs.createReadStream(filename);
    return rstream.pipe(parser);
  };

  Core.prototype.streamPodcast = function(req, res, k) {
    var rangeRequest, rangeVals, requestEnd, requestStart;
    if (req.connection.destroyed) {
      return false;
    }
    rangeRequest = false;
    if (_u.isString(req.headers.range)) {
      rangeVals = req.headers.range.match(/^bytes ?= ?(\d+)?-(\d+)?$/);
      if (rangeVals) {
        rangeRequest = true;
        requestStart = rangeVals[1] != null ? rangeVals[1] - 0 : void 0;
        requestEnd = rangeVals[2] != null ? rangeVals[2] - 0 : void 0;
        if (requestStart && requestEnd && (requestStart > requestEnd)) {
          res.writeHead(416, {
            "Content-type": "text/html"
          });
          res.end("416 Requested Range Not Valid");
          return false;
        }
      } else {
        console.log("Invalid range header? " + req.headers.range);
        res.writeHead(416, {
          "Content-type": "text/html"
        });
        res.end("416 Requested Range Not Valid");
        return false;
      }
    }
    return this.loadPreroll(k.stream_key, req, (function(_this) {
      return function(predata) {
        var fend, fileStart, fsize, fstart, headers, length, prerollEnd, prerollStart, pstart, rangeEnd, rangeStart, readStreamOpts, rstream, _ref, _ref1;
        if (predata == null) {
          predata = null;
        }
        if (req.connection.destroyed) {
          console.debug("Request was aborted.");
          return false;
        }
        fsize = ((predata != null ? predata.length : void 0) || 0) + k.size;
        fend = fsize - 1;
        length = fsize;
        console.debug(req.method, req.url);
        console.debug("size:", fsize);
        console.debug("Preroll data length is : " + ((predata != null ? predata.length : void 0) || 0));
        _this.listeners++;
        rangeStart = 0;
        rangeEnd = fend;
        if (rangeRequest) {
          if ((requestStart != null) && requestStart > fend) {
            headers = {
              "Content-Type": "text/plain"
            };
            res.writeHead(416, headers);
            res.end("416 Requested Range Not Satisfiable");
            return false;
          }
          if ((requestStart != null) && (requestEnd == null)) {
            rangeStart = requestStart;
            rangeEnd = fend;
          } else if ((requestEnd != null) && (requestStart == null)) {
            rangeStart = fend - requestEnd;
            rangeEnd = fend;
          } else {
            rangeStart = requestStart;
            rangeEnd = requestEnd < fend ? requestEnd : fend;
          }
          length = (rangeEnd - rangeStart) + 1;
        }
        headers = {
          "Content-Type": "audio/mpeg",
          "Connection": "close",
          "Transfer-Encoding": "identity",
          "Content-Length": length,
          "Accept-Ranges": "bytes"
        };
        if (rangeRequest) {
          headers["Cache-Control"] = "no-cache";
          headers["Content-Range"] = "bytes " + rangeStart + "-" + rangeEnd + "/" + fsize;
          res.writeHead(206, headers);
        } else {
          res.writeHead(200, headers);
        }
        console.debug("response headers are", headers);
        if (req.method === "HEAD") {
          res.end();
          return true;
        }
        console.debug("creating read stream. " + _this.listeners + " active downloads.");
        prerollStart = ((_ref = k.id3) != null ? _ref.length : void 0) || 0;
        prerollEnd = prerollStart + ((predata != null ? predata.length : void 0) || 0);
        fileStart = prerollEnd;
        if ((k.id3 != null) && rangeStart < k.id3.length) {
          console.debug("Writing id3 of ", k.id3.length, rangeStart, rangeEnd);
          res.write(k.id3.slice(rangeStart, rangeEnd + 1));
        }
        if ((predata != null) && (((rangeStart <= prerollStart && prerollStart < rangeEnd)) || ((rangeStart <= prerollEnd && prerollEnd < rangeEnd)))) {
          pstart = rangeStart - prerollStart;
          if (pstart < 0) {
            pstart = 0;
          }
          console.debug("Writing preroll: ", pstart, rangeEnd - prerollEnd + 1);
          res.write(predata.slice(pstart, rangeEnd - prerollEnd + 1));
        }
        rstream = null;
        if (rangeEnd > fileStart) {
          fstart = rangeStart - fileStart;
          if (fstart < 0) {
            fstart = 0;
          }
          fend = rangeEnd - fileStart + 1;
          if ((_ref1 = k.id3) != null ? _ref1.length : void 0) {
            fstart += k.id3.length;
            fend += k.id3.length;
          }
          readStreamOpts = {
            bufferSize: 256 * 1024,
            start: fstart,
            end: fend
          };
          console.debug("read stream opts are", readStreamOpts);
          rstream = fs.createReadStream(k.filename, readStreamOpts);
          rstream.pipe(res, {
            end: false
          });
          rstream.on("end", function() {
            var _ref2;
            console.debug("(stream end) wrote " + ((_ref2 = res.socket) != null ? _ref2.bytesWritten : void 0) + " bytes. " + _this.listeners + " active downloads.");
            res.end();
            return rstream.destroy();
          });
        } else {
          res.end();
        }
        req.connection.on("end", function() {
          var _ref2;
          console.debug("(connection end) wrote " + ((_ref2 = res.socket) != null ? _ref2.bytesWritten : void 0) + " bytes. " + _this.listeners + " active downloads.");
          if (rstream != null ? rstream.readable : void 0) {
            return rstream != null ? rstream.destroy() : void 0;
          }
        });
        req.connection.on("close", function() {
          console.debug("(conn close) in close. " + _this.listeners + " active downloads.");
          return _this.listeners--;
        });
        return req.connection.setTimeout(30 * 1000, function() {
          res.end();
          if (rstream != null ? rstream.readable : void 0) {
            return rstream != null ? rstream.destroy() : void 0;
          }
        });
      };
    })(this));
  };

  Core.prototype.loadPreroll = function(key, req, cb) {
    var conn, conn_pre_abort, count, opts, query, req_t, _ref, _ref1, _ref2;
    count = this._counter++;
    cb = _u.once(cb);
    console.debug("preroller opts is ", this.options.preroll, key);
    if (!(((_ref = this.options.preroll) != null ? _ref.server : void 0) && ((_ref1 = this.options.preroll) != null ? _ref1.key : void 0) && ((_ref2 = this.options.preroll) != null ? _ref2.path : void 0))) {
      if (typeof cb === "function") {
        cb();
      }
      return true;
    }
    query = qs.stringify(req.query);
    opts = {
      host: this.options.preroll.server,
      path: [this.options.preroll.path, this.options.preroll.key, key, "?" + query].join("/")
    };
    conn = req.connection;
    req_t = setTimeout((function(_this) {
      return function() {
        console.debug("Preroll timeout reached for " + count + ".");
        return conn_pre_abort();
      };
    })(this), 250);
    console.debug("firing preroll request", count);
    req = http.get(opts, (function(_this) {
      return function(rres) {
        var buf_len, buffers;
        console.debug("got preroll response ", count, rres.statusCode);
        if (rres.statusCode === 200) {
          buffers = [];
          buf_len = 0;
          clearTimeout(req_t);
          rres.on("data", function(chunk) {
            buffers.push(chunk);
            return buf_len += chunk.length;
          });
          return rres.on("end", function() {
            var pre_data;
            conn.removeListener("close", conn_pre_abort);
            conn.removeListener("end", conn_pre_abort);
            pre_data = Buffer.concat(buffers, buf_len);
            if (typeof cb === "function") {
              cb(pre_data);
            }
            return true;
          });
        } else {
          conn.removeListener("close", conn_pre_abort);
          conn.removeListener("end", conn_pre_abort);
          if (typeof cb === "function") {
            cb();
          }
          return true;
        }
      };
    })(this));
    req.on("socket", (function(_this) {
      return function(sock) {
        return console.debug("socket granted for ", count);
      };
    })(this));
    req.on("error", (function(_this) {
      return function(err) {
        console.debug("got a request error for ", count, err);
        conn.removeListener("close", conn_pre_abort);
        conn.removeListener("end", conn_pre_abort);
        if (typeof cb === "function") {
          cb();
        }
        return true;
      };
    })(this));
    conn_pre_abort = (function(_this) {
      return function() {
        console.debug("conn_pre_abort called. Destroyed? ", conn.destroyed);
        if (conn.destroyed) {
          console.debug("aborting preroll ", count);
          req.abort();
        }
        return clearTimeout(req_t);
      };
    })(this);
    conn.once("close", conn_pre_abort);
    return conn.once("end", conn_pre_abort);
  };

  return Core;

})();

//# sourceMappingURL=podroller.js.map
