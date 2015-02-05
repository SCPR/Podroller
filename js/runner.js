var Podroller, config_file, core, nconf;

Podroller = require("./podroller");

nconf = require("nconf");

nconf.env().argv();

config_file = nconf.get("config") || nconf.get("CONFIG");

if (config_file) {
  nconf.file({
    file: config_file
  });
}

nconf.defaults({
  debug: false,
  port: 8000,
  prefix: "",
  max_zombie_life: 2 * 60 * 1000
});

core = new Podroller(nconf.get());

//# sourceMappingURL=runner.js.map
