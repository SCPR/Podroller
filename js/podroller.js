var Core, Parser, debug, express, fs, http, https, path, qs, ua, uuid, _,
  __bind = function(fn, me){ return function(){ return fn.apply(me, arguments); }; },
  __slice = [].slice;

_ = require("underscore");

path = require('path');

express = require('express');

fs = require("fs");

http = require("http");

https = require("https");

Parser = (require("sm-parsers")).MP3;

qs = require('qs');

uuid = require("node-uuid");

ua = require('universal-analytics');

debug = require("debug")("podroller");

module.exports = Core = (function() {
  function Core(options) {
    var opts, p, papp, prefix, _ref, _ref1;
    this.options = options;
    this.checkForID3 = __bind(this.checkForID3, this);
    debug("Debug logging is enabled");
    debug("Audio dir is " + this.options.audio_dir);
    if (!fs.existsSync(this.options.audio_dir)) {
      console.error("Audio path is invalid!");
      process.exit();
    }
    this.key_cache = {};
    this.listeners = 0;
    this._counter = 0;
    this.app = express();
    if (Object.keys(this.options.prefixes).length > 0) {
      _ref = this.options.prefixes;
      for (p in _ref) {
        opts = _ref[p];
        papp = this._createApp(p, opts);
        this.app.use(p, papp);
        debug("Registered app handler for " + p);
      }
    } else {
      prefix = this.options.prefix || "/";
      papp = this._createApp(prefix, {
        preroll_key: (_ref1 = this.options.preroll) != null ? _ref1.key : void 0
      });
      this.app.use(prefix);
    }
    this.server = http.createServer(this.app);
    this.server.listen(this.options.port);
    debug("Listening on port " + this.options.port);
  }

  Core.prototype._createApp = function(prefix, opts) {
    var _app;
    _app = express();
    _app.use((function(_this) {
      return function(req, res, next) {
        req.podroller_prefix = prefix;
        return next();
      };
    })(this));
    _app.use(this.onlyValidFiles());
    if (this.options.redirect_url) {
      _app.use(this.injectUUID());
    }
    _app.use(this.requestHandler(opts));
    return _app;
  };

  Core.prototype.onlyValidFiles = function() {
    return (function(_this) {
      return function(req, res, next) {
        var filename;
        req.count = _this._counter++;
        filename = path.join(_this.options.audio_dir, req.path);
        debug("" + req.count + ":" + req.podroller_prefix + ": Path is " + req.path);
        return fs.stat(filename, function(err, stats) {
          if (err || !stats.isFile()) {
            return res.status(404).end();
          } else {
            req.filename = filename;
            req.fstats = stats;
            return next();
          }
        });
      };
    })(this);
  };

  Core.prototype.injectUUID = function() {
    return (function(_this) {
      return function(req, res, next) {
        var id, url;
        if (!req.query.uuid) {
          id = uuid.v4();
          debug("" + req.count + ":" + req.podroller_prefix + ": Redirecting with UUID of " + id + " (" + req.originalUrl + ")");
          url = ("" + _this.options.redirect_url + (req.originalUrl.replace('//', '/'))) + (Object.keys(req.query).length > 0 ? "&uuid=" + id : "?uuid=" + id);
          return res.redirect(302, url);
        } else {
          return next();
        }
      };
    })(this);
  };

  Core.prototype.requestHandler = function(opts) {
    return (function(_this) {
      return function(req, res, next) {
        var mtime, _ref;
        debug("" + req.count + ":" + req.podroller_prefix + ": Request UUID is " + req.query.uuid);
        if (_this.key_cache[req.filename] && ((_ref = _this.key_cache[req.filename]) != null ? _ref.mtime : void 0) === req.fstats.mtime.getTime() && _this.key_cache[req.filename].stream_key) {
          return _this.streamPodcast(req, res, _this.key_cache[req.filename], opts.preroll_key);
        } else {
          mtime = req.fstats.mtime.getTime();
          return _this.checkForID3(req.filename, function(stream_key, id3) {
            var k;
            k = _this.key_cache[req.filename] = {
              filename: req.filename,
              mtime: mtime,
              stream_key: stream_key,
              id3: id3,
              size: req.fstats.size
            };
            return _this.streamPodcast(req, res, k, opts.preroll_key);
          });
        }
      };
    })(this);
  };

  Core.prototype.checkForID3 = function(filename, cb) {
    var parser, rstream, tags;
    parser = new Parser;
    tags = [];
    parser.on("debug", (function(_this) {
      return function() {
        var msgs;
        msgs = 1 <= arguments.length ? __slice.call(arguments, 0) : [];
      };
    })(this));
    parser.once("id3v2", (function(_this) {
      return function(buf) {
        return tags.push(buf);
      };
    })(this));
    parser.once("id3v1", (function(_this) {
      return function(buf) {
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
        debug("tag_buf is " + tag_buf);
        debug("stream_key is " + h.stream_key);
        return cb(h.stream_key, tag_buf);
      };
    })(this));
    rstream = fs.createReadStream(filename);
    return rstream.pipe(parser);
  };

  Core.prototype.streamPodcast = function(req, res, k, preroll_key) {
    var rangeRequest, rangeVals, requestEnd, requestStart;
    if (req.connection.destroyed) {
      return false;
    }
    rangeRequest = false;
    if (_.isString(req.headers.range)) {
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
    return this.loadPreroll(k.stream_key, req, preroll_key, (function(_this) {
      return function(predata) {
        var fend, fileStart, fsize, fstart, headers, length, prerollEnd, prerollStart, pstart, rangeEnd, rangeStart, readStreamOpts, rstream, _decListener, _ref, _ref1;
        if (predata == null) {
          predata = null;
        }
        if (req.connection.destroyed) {
          debug("Request was aborted.");
          return false;
        }
        fsize = ((predata != null ? predata.length : void 0) || 0) + k.size;
        fend = fsize - 1;
        length = fsize;
        debug(req.method, req.url);
        debug("" + req.count + ": size:", fsize);
        debug("" + req.count + ": Preroll data length is : " + ((predata != null ? predata.length : void 0) || 0));
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
        debug("" + req.count + ": response headers are", headers);
        if (req.method === "HEAD") {
          res.end();
          return true;
        }
        debug("" + req.count + ": creating read stream. " + _this.listeners + " active downloads.");
        prerollStart = ((_ref = k.id3) != null ? _ref.length : void 0) || 0;
        prerollEnd = prerollStart + ((predata != null ? predata.length : void 0) || 0);
        fileStart = prerollEnd;
        _decListener = _.once(function() {
          return _this.listeners--;
        });
        if ((k.id3 != null) && rangeStart < k.id3.length) {
          debug("" + req.count + ": Writing id3 of ", k.id3.length, rangeStart, rangeEnd);
          res.write(k.id3.slice(rangeStart, rangeEnd + 1));
        }
        if ((predata != null) && (((rangeStart <= prerollStart && prerollStart < rangeEnd)) || ((rangeStart <= prerollEnd && prerollEnd < rangeEnd)))) {
          pstart = rangeStart - prerollStart;
          if (pstart < 0) {
            pstart = 0;
          }
          debug("" + req.count + ": Writing preroll: ", pstart, rangeEnd - prerollEnd + 1);
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
          debug("" + req.count + ": read stream opts are", readStreamOpts);
          rstream = fs.createReadStream(k.filename, readStreamOpts);
          rstream.pipe(res, {
            end: false
          });
          _this.triggerGAEvent(req, preroll_key, k.filename);
          rstream.on("end", function() {
            var _ref2;
            debug("" + req.count + ": (stream end) wrote " + ((_ref2 = res.socket) != null ? _ref2.bytesWritten : void 0) + " bytes. " + _this.listeners + " active downloads.");
            res.end();
            return rstream.destroy();
          });
        } else {
          res.end();
        }
        req.connection.on("end", function() {
          var _ref2;
          debug("" + req.count + ": (connection end) wrote " + ((_ref2 = res.socket) != null ? _ref2.bytesWritten : void 0) + " bytes. " + _this.listeners + " active downloads.");
          if (rstream != null ? rstream.readable : void 0) {
            if (rstream != null) {
              rstream.destroy();
            }
          }
          return _decListener();
        });
        req.connection.on("close", function() {
          debug("" + req.count + ": (conn close) in close. " + _this.listeners + " active downloads.");
          if (rstream != null ? rstream.readable : void 0) {
            if (rstream != null) {
              rstream.destroy();
            }
          }
          return _decListener();
        });
        return req.connection.setTimeout(30 * 1000, function() {
          debug("" + req.count + ": Connection timeout. Ending.");
          res.end();
          if (rstream != null ? rstream.readable : void 0) {
            if (rstream != null) {
              rstream.destroy();
            }
          }
          return _decListener();
        });
      };
    })(this));
  };

  Core.prototype.triggerGAEvent = function(req, preroll_key, filename) {
    var eventProperties, gaId, reqUuid, visitor;
    if (!this.options.google_analytics) {
      return;
    }
    gaId = this.options.google_analytics.property;
    if (!gaId) {
      return;
    }
    reqUuid = this.isRealDownloadAndReturnsUuid(req);
    if (preroll_key === 'podcast' && reqUuid) {
      visitor = ua(gaId);
      eventProperties = {
        ec: "Podcast",
        ea: "Download",
        el: filename
      };
      if (this.options.google_analytics.custom_dimension) {
        eventProperties[this.options.google_analytics.custom_dimension] = reqUuid;
      }
      return visitor.event(eventProperties).send();
    }
  };

  Core.prototype.isRealDownloadAndReturnsUuid = function(req) {
    if (req.headers['user-agent'] && req.headers['user-agent'].match(/bot/i)) {
      return false;
    }
    if (!req.query || !req.query.uuid) {
      return false;
    }
    return req.query.uuid;
  };

  Core.prototype.loadPreroll = function(stream_key, req, preroll_key, cb) {
    var aborted, conn, conn_pre_abort, count, opts, query, req_t, _ref, _ref1;
    count = req.count;
    cb = _.once(cb);
    if (!(((_ref = this.options.preroll) != null ? _ref.server : void 0) && preroll_key && ((_ref1 = this.options.preroll) != null ? _ref1.path : void 0))) {
      if (typeof cb === "function") {
        cb();
      }
      return true;
    }
    query = qs.stringify(req.query);
    aborted = false;
    opts = {
      host: this.options.preroll.server,
      port: this.options.preroll.port || 80,
      path: [this.options.preroll.path, preroll_key, stream_key, "?" + query].join("/")
    };
    conn = req.connection;
    req_t = setTimeout((function(_this) {
      return function() {
        debug("" + count + ": Preroll timeout reached.");
        conn_pre_abort();
        return cb();
      };
    })(this), 750);
    debug("Firing preroll request", count, opts);
    req = https.get(opts, (function(_this) {
      return function(rres) {
        var buf_len, buffers;
        debug("" + count + ": got preroll response ", rres.statusCode);
        clearTimeout(req_t);
        if (rres.statusCode === 200) {
          buffers = [];
          buf_len = 0;
          rres.on("readable", function() {
            var chunk, _results;
            _results = [];
            while (chunk = rres.read()) {
              buffers.push(chunk);
              _results.push(buf_len += chunk.length);
            }
            return _results;
          });
          return rres.on("end", function() {
            var pre_data;
            conn.removeListener("close", conn_pre_abort);
            conn.removeListener("end", conn_pre_abort);
            pre_data = Buffer.concat(buffers, buf_len);
            cb(pre_data);
            return true;
          });
        } else {
          conn.removeListener("close", conn_pre_abort);
          conn.removeListener("end", conn_pre_abort);
          cb();
          return true;
        }
      };
    })(this));
    req.on("socket", (function(_this) {
      return function(sock) {
        return debug("" + count + ": preroll socket granted");
      };
    })(this));
    req.on("error", (function(_this) {
      return function(err) {
        debug("" + count + ": got a request error.", err);
        conn.removeListener("close", conn_pre_abort);
        conn.removeListener("end", conn_pre_abort);
        if (req_t) {
          clearTimeout(req_t);
        }
        cb();
        return true;
      };
    })(this));
    conn_pre_abort = (function(_this) {
      return function() {
        debug("" + count + ": conn_pre_abort called. Destroyed? ", conn.destroyed);
        if (!aborted) {
          debug("" + count + ": Aborting preroll");
          req.abort();
          aborted = true;
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
