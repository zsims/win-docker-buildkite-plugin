# Win Docker Buildkite Plugin

A [Buildkite plugin](https://buildkite.com/docs/agent/v3/plugins) to easily work with [Windows Docker Containers](https://docs.microsoft.com/en-us/virtualization/windowscontainers/about/) from a Linux agent instance.

This currently only supports builds running within AWS Linux EC2 instances, e.g. the [Elastic CI Stack for AWS](https://github.com/buildkite/elastic-ci-stack-for-aws).

## Why?

 1. [Docker Machine](https://docs.docker.com/machine/) has poor support for running Windows Containers; and
 2. Buildkite has amazing support for Linux, but it relies somewhat heavily on Bash (hooks, plugins, etc) so pure Windows agents would lose some functionality (see https://github.com/buildkite/elastic-ci-stack-for-aws/issues/286); and
 3. Allow an easy way to run steps with-in Windows (via Windows Docker containers); and
 4. Docker Machine is being replaced by Docker Cloud; and
 5. Allow Windows code-bases to easily migrate steps to Linux (with the agent pool); and
 6. Nested virtualisation isn't supported in AWS EC2 (e.g. Run a Windows VM on Linux)

# How it Works

This plugin (currently) works by:

 1. Launching an official Amazon AMI of [Microsoft Windows Server 2016 Core with Containers](https://aws.amazon.com/marketplace/pp/B06XX3NFQF)
    1. The same subnet of the current Elastic CI Stack agent instance will be used
    2. Exposing the (HTTP) Docker daemon port to the Elastic CI Stack agent instance (port 2375)
 2. Configuring the Docker client on the Linux agent to point to the Windows Docker Daemon (a supported use-case of Docker)

Launching a Windows EC2 instance per Buildkite EC2 instance allows security to be locked down, and the auto-scaling nature of Elastic CI to be fully utilised.

```
 AWS EC2                                        AWS EC2
 Amazon Linux 2 (Buildkite AMI)                 Windows Server 2016 w/Containers
+-----------------------------+                 +---------------------------+
| +-------------------------+ |  <<create/use>> | +-----------------------+ |
| |    Your cloned source   +---------------------> Your Windows Container| |
| | code (pipeline.yml, ..) | |                 | +-----------------------+ |
| +-------------+-----------+ |                 | +-----------------------+ |
|               |             |                 | | Windows Container #2  | |
| +-------------+-----------+ |  <<launch>>     | +-----------------------+ |
| |    Win Docker Plugin    +---------------------                          |
| +----+--------------------+ |                 | +-----------------------+ |
|      |                      |                 | |     Docker Daemon     | |
| +----v--------------------+ |  TCP :2375      | +-----------^-----------+ |
| |      Docker Client      +---------------------------------+             |
| +-------------------------+ |                 |                           |
|                             |                 |                           |
| +-------------------------+ |   ping          | +-----------------------+ |
| |      Buildkite Agent    | <-------------------+  Scheduled Shutdown   | |
| +-------------------------+ |                 | +-----------------------+ |
+-----------------------------+                 +---------------------------+
```

# Example

```yml
steps:
  - label: 'Run a Windows Docker container'
    command: 'docker run microsoft/dotnet-samples:dotnetapp-nanoserver'
    plugins:
      zsims/win-docker#v0.0.5:
        aws_instance_type: 't2.medium'
```

## Example with Buildkite Docker Plugin (TBD)

This plugin will **soon** work with the [Buildkite Docker Plugin](https://github.com/buildkite-plugins/docker-buildkite-plugin):

 - [ ] Support "copying" data to the Windows host to allow mounting

Some of the defaults must be overriden (`mount-buildkite-agent`, and `workdir`) as they assume the target container is Linux:

```yml
steps:
  - command: 'echo %GREETING% from Windows'
    plugins:
      zsims/win-docker#v0.0.5:
        aws_instance_type: 't2.medium'
      docker#v1.4.0:
        image: 'microsoft/nanoserver:latest'
        workdir: 'C:/workdir'
        mount-buildkite-agent: false
        shell: 'cmd /c'
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
