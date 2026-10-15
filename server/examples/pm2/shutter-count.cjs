// Root-owned PM2 definition for the shared deploy user.
// cwd stays on the stable symlink so `pm2 startOrRestart` follows new releases.
// The in-repo ecosystem uses bin/start.mjs. package.json start is
// `node dist/src/main.js`. Match whichever path the live process actually runs.
module.exports = {
  apps: [
    {
      name: "shutter-count",
      cwd: "/opt/shutter-count/current",
      script: "bin/start.mjs",
      instances: 1,
      exec_mode: "fork",
      max_memory_restart: "300M",
      kill_timeout: 25000,
      env: {
        NODE_ENV: "production",
        PORT: "3020",
        HOST: "127.0.0.1",
        BASE_PATH: "/shutter",
      },
    },
  ],
};
