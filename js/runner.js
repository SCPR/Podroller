var DEBUG, Podroller, config_file, core, nconf,
  __slice = [].slice;

Podroller = require("./podroller");

nconf = require("nconf");

nconf.env().argv();

config_file = nconf.get("config") || nconf.get("CONFIG");

if (config_file) {
  nconf.file({
    file: config_file
  });
}

DEBUG = nconf.get("debug");

console.debug = function() {
  var messages;
  messages = 1 <= arguments.length ? __slice.call(arguments, 0) : [];
  if (DEBUG) {
    return console.log.apply(console, ["DEBUG:"].concat(__slice.call(messages)));
  }
};

core = new Podroller(nconf.get("podroller"));

//# sourceMappingURL=runner.js.map
