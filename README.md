# SynapseNginxDockerSetup
A sample setup for a Docker Composition for a Matrix Synapse server that's reverse proxied by Nginx. By virtue of Synapse generating files on first run, some configuration files or keys need not be predone. The way how I implemented Nginx results in an empty /etc/nginx/ folder, so those files need to be populated.
