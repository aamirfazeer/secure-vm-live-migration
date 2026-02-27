# Workloads

## Memcached

***Setting up memcached in VM***
    
- `apt install memcached` :  To install memcached to the VM 
- `/etc/init.d/memcached stop` :  Execute this command to stop memcached in VM after installation
- `rm /etc/init.d/memcached` :  Remove this file to disbale memcached from starting in startup

***Setting up memaslap bencmark***

Extarct the `libmemcached-1.0.18.tar` to you client server and patch it with `libmemcached-1.0.18-patch`.

Then run the following commands to install memaslap:
    - Edit the Makefile.am to include the follwoing LDFLAGS. : `LDFLAGS = -L/lib64 -lpthread` 
    - Then recreate aclocal.m4 : `aclocal`
    - Now regenerate Makefile.in using following command : `automake`
    - Then generate Makefile using following command : `autoconf`

***Configuring Memaslap***

The default configuration file `.memslap.conf` is saved in `~` directory. You can modifiy this file for your need.

```
    #comments should start with '#'
    #key
    #start_len end_len proportion
    #
    #key length range from start_len to end_len
    #start_len must be equal to or greater than 16
    #end_len must be equal to or less than 250
    #start_len must be equal to or greater than end_len
    #memaslap will generate keys according to the key range
    #proportion: indicates keys generated from one range accounts for the total
    generated keys
    #
    #example1: key range 16~100 accounts for 80%
    #          key range 101~200 accounts for 10%
    #          key range 201~250 accounts for 10%
    #          total should be 1 (0.8+0.1+0.1 = 1)
    #
    #          16 100 0.8
    #          101 200 0.1
    #          201 249 0.1
    #
    #example2: all keys length are 128 bytes
    #
    #          128 128 1
    key
    128 128 1
    #value
    #start_len end_len proportion
    #
    #value length range from start_len to end_len
    #start_len must be equal to or greater than 1
    #end_len must be equal to or less than 1M
    #start_len must be equal to or greater than end_len
    #memaslap will generate values according to the value range
    #proportion: indicates values generated from one range accounts for the
    total generated values
    #
    #example1: value range 1~1000 accounts for 80%
    #          value range 1001~10000 accounts for 10%
    #          value range 10001~100000 accounts for 10%
    #          total should be 1 (0.8+0.1+0.1 = 1)
    #
    #          1 1000 0.8
    #          1001 10000 0.1
    #          10001 100000 0.1
    #
    #example2: all value length are 128 bytes
    #
    #          128 128 1
    value
    2048 2048 1
    #cmd
    #cmd_type cmd_proportion
    #
    #currently memaslap only testss get and set command.
    #
    #cmd_type
    #set     0
    #get     1
    #
    #example: set command accounts for 50%
    #         get command accounts for 50%
    #         total should be 1 (0.5+0.5 = 1)
    #
    #         cmd
    #         0    0.5
    #         1    0.5
    cmd
    0    0.1 
    1.0 0.9
```

***Starting Memcached in VM***

- `memcached -u root -t 4 -m <required_workingset_size>` : Execute the following command to start memcached in vm and  provide `required_workingset_size` in MB

***Starting Memaslap in Client***

Execute the following command.

- `<path>/libmemcached-1.0.18/clients/memaslap -s <vms_ip>:11211 -c <concurrency>` 

