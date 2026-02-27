#script to execute the sysbench within a VM
#copy this file to a VM and execute this using ssh

sysbench --test=cpu --cpu-max-prime=5000000 run > output.log 2>&1 &