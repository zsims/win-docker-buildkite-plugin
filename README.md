# Win Docker Buildkite Plugin

A [Buildkite plugin](https://buildkite.com/docs/agent/v3/plugins) to easily work with [Windows Docker Containers](https://docs.microsoft.com/en-us/virtualization/windowscontainers/about/).

This currently only supports builds running within the [Elastic CI Stack for AWS](https://github.com/buildkite/elastic-ci-stack-for-aws).

## Why?

 1. [Docker Machine](https://docs.docker.com/machine/) has poor support for running Windows Containers; and
 2. Buildkite has amazing support for Linux, but it relies somewhat heavily on Bash (hooks, plugins, etc) so pure Windows agents would lose some functionality; and
 3. Allow an easy way to run steps with-in Windows (via Windows Docker containers); and
 4. Docker Machine is being replaced by Docker Cloud; and

# How it Works

This plugin (currently) works by:

 1. Launching an official Amazon AMI of [Microsoft Windows Server 2016 Core with Containers](https://aws.amazon.com/marketplace/pp/B06XX3NFQF)
   1. The same subnet of the current Elastic CI Stack agent instance will be used
   2. Exposing the (HTTP) Docker daemon port to the Elastic CI Stack agent instance (port 2375)
 2. Configuring the Docker daemon

Launching a Windows EC2 instance per Buildkite EC2 instance allows security to be locked down, and the auto-scaling nature of Elastic CI to be fully utilised.

# Example

```yml
steps:
  - label: 'Run a Windows Docker container'
    command: 'docker run microsoft/dotnet-samples:dotnetapp-nanoserver'
    plugins:
      zsims/win-docker#0.0.1:
        host:
          aws_instance_type: 't2.medium'
```

## Example with Buildkite Docker Plugin

This plugin will also work with the [Buildkite Docker Plugin](https://github.com/buildkite-plugins/docker-buildkite-plugin):

```yml
steps:
  - command: 'echo %GREETING% from Windows'
    plugins:
      zsims/win-docker#0.0.1:
        host:
          aws_instance_type: 't2.medium'
      docker#v1.4.0:
        image: 'microsoft/nanoserver:latest'
        environment:
          - GREETING=Hello
```

# Tests

To run the tests of this plugin, run
```sh
docker-compose run --rm tests
```

# License

MIT (see [LICENSE](LICENSE))
