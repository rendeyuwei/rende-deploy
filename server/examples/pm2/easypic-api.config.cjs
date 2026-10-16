// Root-owned PM2 definition. The filename must end in .config.cjs (or start
// with ecosystem). PM2 otherwise runs the file as a script and the app never
// starts. The start script reads /etc/easypic/easypic.env.
// That file is mode 0600 root today. Before cutover, let rende-deploy read it
// (for example mode 0640 root:rende-deploy) without copying it into the repo.
module.exports = {
  apps: [
    {
      name: "easypic-api",
      cwd: "/opt/easypic/current",
      script: "deploy/start-api.sh",
      interpreter: "bash",
      instances: 1,
      exec_mode: "fork",
    },
  ],
};
