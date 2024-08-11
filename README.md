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

Before "avahi-backup" i had a bash script for my backup with something like:
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

# Process overview

```plantuml

@startuml 

box "Client"
   participant "avahi-backup.client" as client
   participant "local Storage" as local.storage
end box

box "Network"
   participant "LAN" as lan
   participant "AVAHI" as avahi.announcement
end box

box "Server"
   participant "avahi-backup.backup" as backup
   participant "Backup-Target" as backup.storage 
end box

== Setup ==

backup -> backup.storage: Mark as backup-rooot

note left of backup.storage

./avahi-backup init-backup-root

... marks the current directory as root 
of backups (currently it has to be a zfs based setup)

end note

backup -> client: shares ssh keys for root access

note left of backup
./avahi-backup setup <client> [alternative primary logon-account see 1)]

1) if root only works with public keys, therefore a intermediary account is needed.

e.g.
./avahi-backup setup 192.168.0.34 user1
will ssh user1@192.168.0.34 sudo cat >> /root/.ssh/authorized_keys

2) if direct root login is enabled
./avahi-backup setup 192.168.0.34
will ssh-copy-id root@192.168.0.34 cat >> /root/.ssh/authorized_keys

end note

== Client start ==

client -> local.storage: scans for /home/*/.backup if found registers
client -> local.storage: reads /etc/backup.d/*.conf and registers
client -> avahi.announcement: Default register /etc /root + found ones

== Backup Cycle ==

backup -> avahi.announcement: reads service announcements from network
backup -> client: rsyncs or zfs send announced sources to server
client -> backup.storage: copy backup (full or incremental)

@enduml



```
