// Root-owned PM2 definition for the shared deploy user.
// The filename must end in .config.cjs (or start with ecosystem). PM2
// otherwise runs the file as a script and the app never starts.
// cwd stays on the stable symlink so `pm2 startOrRestart` follows new releases.
// The in-repo ecosystem uses bin/start.mjs. package.json start is
// `node dist/src/main.js`. Match whichever path the live process actually runs.
// MAX_UPLOAD_MB, TRUST_PROXY, and SHUTTER_APP_DIR are the documented defaults:
// 50, loopback proxies only, and the current symlink.
// interpreter is the Node 22 binary from path_extra in shutter.conf.
module.exports = {
  apps: [
    {
      name: "shutter-count",
      cwd: "/opt/shutter-count/current",
      script: "bin/start.mjs",
      interpreter: "/opt/node-v22.23.2-linux-x64/bin/node",
      instances: 1,
      exec_mode: "fork",
      max_memory_restart: "300M",
      kill_timeout: 25000,
      env: {
        NODE_ENV: "production",
        PORT: "3020",
        HOST: "127.0.0.1",
        BASE_PATH: "/shutter",
        MAX_UPLOAD_MB: "50",
        TRUST_PROXY: "127.0.0.1,::1",
        SHUTTER_APP_DIR: "/opt/shutter-count/current",
      },
    },
  ],
};
