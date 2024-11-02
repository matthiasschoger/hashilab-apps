<h1>Hashilab Apps</h1>

<h2>Motivation</h2>

This project was born out of boredom during the Covid epedemic, when I wanted to replace my already existing Docker homelab with something more advanced. After playing around with k8s for a bit, I decided that Nomad is a great fit for a hobby project, compared to k8s which felt more like something you would do for a job.

With k8s, it felt to me like I was reciting the rotes of the church of Helm, without really understanding what I was doing or why. With Nomad and Consul, I could "grok" the concepts without making it a job and find solutions to the specific issues I was facing.

<h2>Goals of this project</h2>

My main goals for my new homelab were the following
- Resiliency - which means high-availablity to me. I want to shut down or lose any node, and my cluster should heal itself, with all services being available again.
- I'm a sucker for graph p*rn, and want to have as much insight as possible into what my homelab is currently doing.
- Scratch my technical itch. Since I move into a sales position right before Covid, I needed some tech stuff to do.

To keep the jobs manageable, I've split them into three repositories
- [hashilab-core](https://github.com/matthiasschoger/hashilab-core): Basic infrastructure which contains load-balancing, reverse proxy, DNS and ingress management
- [hashilab-support](https://github.com/matthiasschoger/hashilab-support): Additional operational stuff like metrics management and visualization, maintenance tasks and much more stuff to run the cluster more effienctly
- [hashilab-apps](https://github.com/matthiasschoger/hashilab-apps): End-user apps like Vaultwarden or Immich


<h2>Hashilab-apps</h2>

The "apps" repository defines end-user applications running on the cluster. Used by me and my family to manage our home automations, mobile phone images and family passwords.

- adguard - DNS filering to make sure that tracking and ads are limited to a minimum on our home network. Some magic is involved in core-dns to make sure that DNS still works if the adguard service is down.
- bookstack - My internal wiki where I keep all the notes to my setup.
- gitea - Local git which keeps all my IaC code.
- home-assistant - Currently mainly used to bridge my IoT hardware to Homekit.
- immich - Awesome image management tool which handles image backup and management for the family. Great example how to scale a complex application in a Nomad/Consul cluster.
- nginx-web - Static web page if you happen to stumble across my domain.
- node-red - More home automation.
- unifi-network - Controller application for the Unifi network stack from Ubiquiti Networks. Was quite tricky to set up in a HA environment, please check consul-ingress for UDP forwarding.
- vaultwarden - Password management for the family.
