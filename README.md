![](.gitbook/assets/logo.png)

[![Build Status](https://github.com/kubearmor/KubeArmor/actions/workflows/ci-test-ginkgo.yml/badge.svg)](https://github.com/kubearmor/KubeArmor/actions/workflows/ci-test-ginkgo.yml/)
[![CII Best Practices](https://bestpractices.coreinfrastructure.org/projects/5401/badge)](https://bestpractices.coreinfrastructure.org/projects/5401)
[![CLOMonitor](https://img.shields.io/endpoint?url=https://clomonitor.io/api/projects/cncf/kubearmor/badge)](https://clomonitor.io/projects/cncf/kubearmor)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/kubearmor/kubearmor/badge)](https://securityscorecards.dev/viewer/?uri=github.com/kubearmor/KubeArmor)
[![FOSSA Status](https://app.fossa.com/api/projects/git%2Bgithub.com%2Fkubearmor%2FKubeArmor.svg?type=shield&issueType=license)](https://app.fossa.com/projects/git%2Bgithub.com%2Fkubearmor%2FKubeArmor?ref=badge_shield)
[![FOSSA Status](https://app.fossa.com/api/projects/git%2Bgithub.com%2Fkubearmor%2FKubeArmor.svg?type=shield&issueType=security)](https://app.fossa.com/projects/git%2Bgithub.com%2Fkubearmor%2FKubeArmor?ref=badge_shield)
[![Slack](https://img.shields.io/badge/Join%20Our%20Community-Slack-blue)](https://cloud-native.slack.com/archives/C02R319HVL3)
[![Discussions](https://img.shields.io/badge/Got%20Questions%3F-Chat-Violet)](https://github.com/kubearmor/KubeArmor/discussions)
[![Docker Downloads](https://img.shields.io/docker/pulls/kubearmor/kubearmor)](https://hub.docker.com/r/kubearmor/kubearmor)
[![ArtifactHub](https://img.shields.io/badge/ArtifactHub-KubeArmor-blue?logo=artifacthub&labelColor=grey&color=green)](https://artifacthub.io/packages/search?kind=19)

**KubeArmor restricts what your workloads are allowed to do.** It controls process execution, file
access, and network operations for pods, containers, and hosts.

Most runtime security tools watch an action, then react. They kill the process or quarantine the pod
*after* the code runs. KubeArmor decides inside the kernel, at a Linux Security Module hook, before
the action completes. An unauthorized `exec` returns `Permission denied`. Nothing runs first.

|  |   |
|:---|:---|
| 💪 **[Harden Infrastructure](getting-started/hardening_guide.md)** <hr>🔗 Protect critical paths such as cert bundles <br>📋 MITRE, STIGs, CIS based rules <br>🧳 Restrict access to raw DB tables | 💍 **[Least Permissive Access](getting-started/least_permissive_access.md)** <hr>🚦 Process allow-listing <br>🚦 Network allow-listing <br>🎛️ Control access to sensitive assets |
| 🔭 **[Application Behavior](getting-started/workload_visibility.md)** <hr>🧬 Process execs, file system accesses <br>🧭 Service binds, ingress, egress connections <br>🔬 Sensitive system call profiling | ❄️ **[Deployment Models](getting-started/deployment_models.md)** <hr>☸️ Kubernetes deployment<br>🐳 Containerized deployment<br>💻 VM and bare-metal deployment |

## Install in 2 minutes

```sh
helm repo add kubearmor https://kubearmor.github.io/charts
helm repo update kubearmor
helm upgrade --install kubearmor-operator kubearmor/kubearmor-operator -n kubearmor --create-namespace
kubectl apply -f https://raw.githubusercontent.com/kubearmor/KubeArmor/main/pkg/KubeArmorOperator/config/samples/sample-config.yml
```

No node changes. No container runtime swap. Full walkthrough in the
[deployment guide](getting-started/deployment_guide.md).

## Architecture

One non-privileged DaemonSet pod per node. The daemon turns policy into kernel rules, and the
enforcer loads them through whichever LSM the node runs.

<img src=".gitbook/assets/diagrams/fig1-architecture.svg" alt="KubeArmor components. The control plane supplies policy custom resources, the operator with its snitch job, and the controller. On each node one DaemonSet pod runs the daemon, system monitor, runtime enforcer, and log feeder. The enforcer loads rules into kernel LSM hooks, which allow or deny each syscall inline. A dashed path copies events upward for telemetry only. The log feeder streams to the karmor CLI, the relay server, and downstream sinks." width="100%">

Two things leave that flow, and the difference matters:

- **Orange is the decision.** It happens at the LSM hook, in kernel space, on the call the workload
  just made.
- **Dashed blue is a copy of the event**, for telemetry only. A dropped event costs you a log line.
  It never weakens enforcement, because enforcement never waits for userspace.

Container identity comes from the runtime, through the CRI socket today and through
[OCI hooks](https://kubearmor.io/blog/kubearmor-oci-hooks-container-security) in newer deployments.
OCI hooks remove the last privileged mount from the install.

## Where the decision happens

Falco, Tetragon, and KubeArmor all see the same syscall. They act at different points on the same
timeline.

<img src=".gitbook/assets/diagrams/fig2-decision-point.svg" alt="Two timelines for the same syscall. In the detect and respond model the syscall completes, a probe copies the event, a userspace engine matches a rule, and a kill or quarantine response lands milliseconds to minutes later, by which time the data is read or gone. In the inline model the LSM hook checks the rule inside the same syscall, which returns Permission denied, so nothing ran." width="100%">

The upper path needs three steps to finish. An attacker breaks it two ways: flood the event buffer
so the event never ships, or just finish the job first. Ransomware deletes a file in milliseconds.

The lower path has no steps to break.

## How KubeArmor compares

| Engine | Model | Inline block | Allow-list policy | Sandboxing | Hardened distros | Overhead |
|---|---|:-:|:-:|:-:|:-:|:-:|
| **KubeArmor** | detect + inline LSM enforcement | ✅ | ✅ | ✅ | ✅ | Low |
| Tetragon | detect + kill or override return | ⚠️ | ✅ | ❌ | ⚠️ | Low |
| Falco + Talon | detect and respond | ❌ | ❌ | ❌ | ✅ | High |
| Tracee | detect only | ❌ | ❌ | ❌ | ✅ | High |
| NeuVector | detect + kill from userspace | ❌ | ✅ | ❌ | ✅ | High |
| gVisor | syscall interception in a guest kernel | ✅ | ✅ | ✅ | ❌ | High |
| Prisma Defender | runC shim replacement | ✅ | ✅ | ✅ | ⚠️ | High |

Three things explain that table:

- **eBPF observes, LSMs enforce.** kprobes and tracepoints report an event. They cannot reject a
  syscall. `bpf_override_return()` can, but its own man page warns of security implications, and it
  needs `CONFIG_FUNCTION_ERROR_INJECTION` plus an error-injectable syscall. Most server distros ship
  without it.
- **A kill signal arrives after the code ran.** Post-attack response is open to TOCTOU bypass and to
  event floods that overflow the ring buffer. An LSM hook has neither problem.
- **No host change, no runC swap.** Engines that replace the runtime binary cannot install on
  Bottlerocket, Talos, or GKE COS without manual node work.

Source: *Container Runtime Security, Comparative Insights, 2025 Edition* (Rahul Jadhav). Longer
version: [differentiation](getting-started/differentiation.md).

## Recent attacks, and the policy that stops them

Five campaigns, five write-ups, one shared chain. KubeArmor puts a gate at three steps of it.

<img src=".gitbook/assets/diagrams/fig4-attack-chain.svg" alt="The five stages every recent container attack walks through: initial access, run the payload, harvest secrets, spread or exfiltrate, and impact. Three KubeArmor policy gates cut the chain. An allow-list on process execution stops the payload from starting, denied reads on secret paths stop credential harvesting, and denied unlisted egress stops spread and exfiltration. Five published 2025 campaigns are mapped to the gate that stops each one." width="100%">

| Attack | What happened | Where KubeArmor cuts the chain |
|---|---|---|
| **React2Shell**<br>CVE-2025-55182, Dec 2025 | Unauthenticated RCE gave shell access inside pods. Actors harvested mounted service account tokens, queried RBAC, then deployed miners. [Unit 42](https://unit42.paloaltonetworks.com/modern-kubernetes-threats/) | Deny reads on `/var/run/secrets/kubernetes.io/serviceaccount/token`. Allow-list the app process, so `curl` and the miner never execute. |
| **Shai-Hulud npm worm**<br>Sep and Nov 2025 | A `postinstall` script harvested npm tokens, GitHub PATs, and cloud keys, then published them to public repos. A later variant wiped the home directory. [Wiz](https://www.wiz.io/blog/shai-hulud-npm-supply-chain-attack) | In CI and build pods, deny reads on `~/.npmrc`, `~/.aws/credentials`, and SSH keys. Deny egress except the registry. Deny writes outside the workspace. |
| **IngressNightmare**<br>CVE-2025-1974, Mar 2025 | Unauthenticated RCE in the ingress-nginx admission controller, whose service account can read Secrets in every namespace. [Wiz](https://www.wiz.io/blog/ingress-nginx-kubernetes-vulnerabilities) | Allow only `nginx` and its workers to execute in that pod. Deny writes to `/etc/nginx`. Deny the token read the next step needs. |
| **Dero miner in containers**<br>2025 | Attackers reached exposed Docker APIs, then a worm installed `masscan` and a Docker client inside running containers to spread. [Securelist](https://securelist.com/dero-miner-infects-containers-through-docker-api/116546/) | Deny `apt`, `apk`, `yum`. Deny `docker` and `kubectl` binaries in workload pods. Deny access to `/var/run/docker.sock`. |
| **nullifAI models**<br>Hugging Face, Feb 2025 | Two models carried pickle payloads that opened a reverse shell on load. The platform scanner did not flag them. [ReversingLabs](https://www.reversinglabs.com/blog/rl-identifies-malware-ml-model-hosted-on-hugging-face) | Sandbox the inference pod. Allow only the Python binary. Deny shell spawn, raw sockets, and unlisted egress. |

Every cell in the last column is a policy line, not a detection rule.
[policy-templates](https://github.com/kubearmor/policy-templates) ships them, and `karmor recommend`
generates them per workload. MITRE and CIS mapping:
[hardening guide](getting-started/hardening_guide.md).

## Sandboxing AI agents

An agent is a process with tools. Guardrails read the prompt and the answer. They do not stop the
command the agent runs once a prompt injection works.
[ModelArmor](https://docs.kubearmor.io/kubearmor/use-cases/modelarmor) uses KubeArmor to bound that
process.

<img src=".gitbook/assets/diagrams/fig3-agent-sandbox.svg" alt="An agent process inside a pod. One allowed edge runs the listed interpreter and reads the application directory. Four attempted edges hit the KubeArmor policy gate and are denied in kernel space: spawning a shell or network scanner, reading cloud credentials and the service account token, opening a raw socket to an unlisted host, and writing then executing a script in slash tmp." width="100%">

| Risk | What the attacker gets | Policy control |
|---|---|---|
| Prompt injection to shell | agent runs `curl`, `nmap`, `apk add` | Allow only the interpreter binary. Deny every other exec. |
| Credential theft | reads `/root/.aws/credentials`, the SA token | Block reads on secret paths. Allow the app path only. |
| Model supply chain payload | a pickle load opens a reverse shell | Deny raw sockets and unlisted egress from the model pod. |
| Persistence in the sandbox | writes a script to `/tmp`, then runs it | Deny write plus exec on writable directories. |

Works with any language runtime or AI framework, including tool-calling agents, MCP servers, and
inference servers such as NVIDIA NIM. No application change, and no MicroVM.

- [ModelArmor overview](https://docs.kubearmor.io/kubearmor/use-cases/modelarmor)
- [Pickle code injection PoC](https://docs.kubearmor.io/kubearmor/use-cases/modelarmor/modelarmor-pickle-code)
- [modelarmor repository](https://github.com/kubearmor/modelarmor)

## Performance

Enforcement runs in the kernel, so the decision costs no context switch. Measured on 4-node AKS,
DS2_v2, sock-shop, Apache Bench at 50,000 requests and 5,000 concurrent:

| Case | Throughput (req/s) | Latency (ms) | KubeArmor CPU | KubeArmor memory | Failed requests |
|---|:-:|:-:|:-:|:-:|:-:|
| No KubeArmor | 2205.5 | 0.4534 | — | — | 0 |
| KubeArmor + policies (AppArmor) | 2169.4 | 0.4609 | 141 m | 112 Mi | 0 |

A 1.6% throughput cost for one node agent at roughly 0.14 cores.

> Numbers are from the [March 2023 benchmark run](https://kubearmor.io/blog/KubeArmor-Performance-Benchmarking-Data)
> on the v1.0 line, including the BPF-LSM tables. A current-release re-run is open work.

## Documentation 📓

* 👉 [Getting Started](getting-started/deployment_guide.md)
* 🎯 [Use Cases](getting-started/use-cases/hardening.md)
* ✔️ [KubeArmor Support Matrix](getting-started/support_matrix.md)
* ♟️ [How is KubeArmor different?](getting-started/differentiation.md)
* 📜 Security Policy for Pods/Containers [[Spec](getting-started/security_policy_specification.md)] [[Examples](getting-started/security_policy_examples.md)]
* 📜 Cluster level security Policy for Pods/Containers [[Spec](getting-started/cluster_security_policy_specification.md)] [[Examples](getting-started/cluster_security_policy_examples.md)]
* 📜 Security Policy for Hosts/Nodes [[Spec](getting-started/host_security_policy_specification.md)] [[Examples](getting-started/host_security_policy_examples.md)]
* 📜 Network Security Policy for Hosts/Nodes [[Spec](getting-started/network_security_policy_specification.md)] [[Examples](getting-started/network_security_policy_examples.md)]<br>
... [detailed documentation](https://docs.kubearmor.io/kubearmor/)

### Contributors 👥

* 📘 [Contribution Guide](contribution/contribution_guide.md)
* 🧑‍💻 [Development Guide](contribution/development_guide.md), [Testing Guide](contribution/testing_guide.md)
* ✋ [Join KubeArmor Slack](https://cloud-native.slack.com/archives/C02R319HVL3)
* ❓ [FAQs](getting-started/FAQ.md)

### Biweekly Meeting

- 🗣️ [Zoom Link](http://zoom.kubearmor.io)
- 📄 Minutes: [Document](https://docs.google.com/document/d/1IqIIG9Vz-PYpbUwrH0u99KYEM1mtnYe6BHrson4NqEs/edit)
- 📅 Calendar invite: [Google Calendar](http://www.google.com/calendar/event?action=TEMPLATE&dates=20220210T150000Z%2F20220210T153000Z&text=KubeArmor%20Community%20Call&location=&details=%3Ca%20href%3D%22https%3A%2F%2Fdocs.google.com%2Fdocument%2Fd%2F1IqIIG9Vz-PYpbUwrH0u99KYEM1mtnYe6BHrson4NqEs%2Fedit%22%3EMinutes%20of%20Meeting%3C%2Fa%3E%0A%0A%3Ca%20href%3D%22%20http%3A%2F%2Fzoom.kubearmor.io%22%3EZoom%20Link%3C%2Fa%3E&recur=RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TH&ctz=Asia/Calcutta), [ICS file](getting-started/resources/KubeArmorMeetup.ics)

### Community & Governance

KubeArmor is a community-governed project. These documents describe how it is run:

| Document | What it covers |
|---|---|
| 📜 [Governance](./GOVERNANCE.md) | Roles, decision-making, vendor neutrality, sub-teams, voting. |
| 👥 [Maintainers](./MAINTAINERS.md) | Current Maintainers, Reviewers, and Emeritus, with affiliations. |
| 🤝 [Code of Conduct](./CODE_OF_CONDUCT.md) | We follow the [CNCF Code of Conduct](https://github.com/cncf/foundation/blob/main/code-of-conduct.md). |
| 📦 [Release Process](./RELEASES.md) | Cadence, release candidates, release manager, support window. |
| 🔒 [Security Policy](./SECURITY.md) | How to report a vulnerability. |

## Notice/Credits 🤝

- KubeArmor uses [Tracee](https://github.com/aquasecurity/tracee/)'s system call utility functions.

## CNCF

KubeArmor is a [Sandbox Project](https://www.cncf.io/projects/kubearmor/) of the Cloud Native Computing Foundation.
![CNCF SandBox Project](.gitbook/assets/cncf-sandbox.png)

## ROADMAP

KubeArmor roadmap is tracked via [KubeArmor Projects](https://github.com/orgs/kubearmor/projects?query=is%3Aopen)

## Related Repositories

KubeArmor is more than a single repository. The repositories below, under the
[`kubearmor`](https://github.com/kubearmor) GitHub organization, are part of the wider project. Each
is governed under [GOVERNANCE.md](./GOVERNANCE.md), see the *Subprojects* section for how core and
community subprojects are classified.

> **Note:** This list covers actively maintained repositories. For the complete list, including
> archived ones, see the [organization page](https://github.com/orgs/kubearmor/repositories).

### Core

| Repository | What it is |
|---|---|
| [KubeArmor](https://github.com/kubearmor/KubeArmor) | The main runtime security enforcement daemon. This repository. |
| [kubearmor-client](https://github.com/kubearmor/kubearmor-client) | `karmor`, the official command-line tool for installing, configuring, and observing KubeArmor. |
| [charts](https://github.com/kubearmor/charts) | Official Helm charts for KubeArmor and the KubeArmor Operator. |
| [policy-templates](https://github.com/kubearmor/policy-templates) | Community-curated library of System and Network policy templates for KubeArmor (and Cilium). |
| [kubearmor.io](https://github.com/kubearmor/kubearmor.io) | Source for the [kubearmor.io](https://kubearmor.io) website. |
| [.project](https://github.com/kubearmor/.project) | Project metadata for CNCF `.project` automation (CLOMonitor, landscape, etc.). |

### Integrations and adapters

| Repository | What it is |
|---|---|
| [otel-adapter](https://github.com/kubearmor/otel-adapter) | OpenTelemetry receiver for KubeArmor events and alerts. |
| [kubearmor-prometheus-exporter](https://github.com/kubearmor/kubearmor-prometheus-exporter) | Prometheus exporter for KubeArmor metrics. |
| [kubearmor-relay-server](https://github.com/kubearmor/kubearmor-relay-server) | Relay/log streaming server that aggregates events from KubeArmor agents. |
| [kubearmor-kafka-client](https://github.com/kubearmor/kubearmor-kafka-client) | Kafka client for streaming KubeArmor logs to a Kafka cluster. |
| [kubearmor-log-client](https://github.com/kubearmor/kubearmor-log-client) | Standalone log client (stdout or file) for consuming KubeArmor logs. |
| [grafana-datasource](https://github.com/kubearmor/grafana-datasource) | Grafana data source backend for visualising KubeArmor data. |
| [kubearmor-dashboards](https://github.com/kubearmor/kubearmor-dashboards) | ELK-stack dashboards for KubeArmor logs and alerts. |
| [kubearmor-action](https://github.com/kubearmor/kubearmor-action) | GitHub Action that runs KubeArmor against a workload for CI security checks. |
| [rancherui](https://github.com/kubearmor/rancherui) | Rancher Manager UI extension for managing KubeArmor through Rancher. |
| [sidekick](https://github.com/kubearmor/sidekick) | Glue to connect KubeArmor events into downstream ecosystems. |

### Deployment and packaging

| Repository | What it is |
|---|---|
| [custom-packages](https://github.com/kubearmor/custom-packages) | Custom `.deb` / `.rpm` packaging definitions. |
| [packer-plugin-kubearmor](https://github.com/kubearmor/packer-plugin-kubearmor) | HashiCorp Packer plugin for baking KubeArmor into images. |

### Specialised projects

| Repository | What it is |
|---|---|
| [k8tls](https://github.com/kubearmor/k8tls) | (Pronounced *cattles*) — assesses server port security by detecting TLS and certificate configuration. |
| [modelarmor](https://github.com/kubearmor/modelarmor) | ML and AI workload security, including the pickle-injection PoC and adversarial-attack demos. |
| [kvm-service](https://github.com/kubearmor/kvm-service) | Service for orchestrating KubeArmor policies to VMs and bare-metal hosts via either a Kubernetes or non-Kubernetes control plane. |
| [libbpf](https://github.com/kubearmor/libbpf) | Go eBPF helper library based on the upstream libbpf API. |
| [kbc](https://github.com/kubearmor/kbc) | KubeArmor Benchmark Calculator. |

<!--
TODO: Confirm classification of each repository as **core subproject** (governed by this repo's GOVERNANCE.md, CODEOWNERS subset of Maintainers) versus **community subproject** (own MAINTAINERS file, autonomous on technical decisions but bound by CoC and vendor-neutrality clauses). This is CNCF DD blocker F.

Also, the following repositories have not been pushed to in over 12 months and may be candidates for archiving — confirm with Maintainers before next release:
  artefacts, certified-operators, marketplace-kubernetes, minikube, kubearmor.github.io, openhorizon-demo (already archived), test-enterprise-gha, runtime-security-best-practices, log4j-CVE-2021-44228, kastore, koach, KubeArmor-demo (last push 2023), tag-security, kubearmor-relay-server-KA (looks duplicated).
-->

This list is generated iteratively — open a pull request to add a new repository or correct a description.
