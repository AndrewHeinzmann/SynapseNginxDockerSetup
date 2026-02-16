# SynapseNginxDockerSetup
A sample setup for a Docker Composition for a Matrix Synapse server that's reverse proxied by Nginx. By virtue of Synapse generating files on first run, some configuration files or keys need not be predone. The way how I implemented Nginx results in an empty /etc/nginx/ folder, so those files need to be populated.

The configuration for Synapse has federation disabled since I have yet to currently use the Matrix server beyond simple testing.

Assumptions:
1. Docker is being run as rootless, so it requires the Docker user to have sudo privileges. This currently prevents it from being a userless deployment.
2. Certificates are already installed by Certbot for LetsEncrypt.
3. Any stored secrets in .env are simple alphanumeric strings without special characters like quotes.
4. Server name is manually entered into start.sh (I should really program .env functionality further)
