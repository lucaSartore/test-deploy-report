
# Minimal Installation Procedure (Online Deployment)
The minimal steps you need to take for a successful deployment are:
 - Run `scripts.delivery.sh` to ensure you have the latest deployment scripts
 - ensure all dependencies are satisfied using `dependencies.install.sh`
 - ensure you are correctly logged inside `docker` and `gh`
 - create the env file using `configure.sh` (only necessary for the first deployment)
 - run the deployment using `deploy.sh`
