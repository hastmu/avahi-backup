# avahi-backup
avahi based Backup as a Service (BaaS) ;)

# Roadmap

* [X] Show up at github
* [ ] PoC
* [ ] First full release
* [ ] deb installation procedure

# what is this?

Avahi backup is a backup concept i developed after my last maturing step of my backup concept for my home setup.

How does my home setup look like:
- Proxmox server
- Debian Notebooks
- Family deb packages to configure everything, like family-notebook.deb for what a notebook should have etc...

Before "avahi-backup" i add a bash script for my backup with something like:
```bash
declare -A backup
backup[root@192.168.0.4]="/opt:/export/disk1/backup/192.168.0.4/opt"
backup[root@192.168.0.4]="/home:/export/disk1/backup/192.168.0.4/home"
...
```

so all handcrafted entries.

Now it looks like:
- backup clients define a avahi-publish for "_backup._tcp" with TXT like - "path=/home/user1" "path=/etc" "path=/root" "path=/export/disk4-ssd/data"
- the central backup script looks for "_backup._tcp" and rsyncs all TXT definitions to the local backup location


