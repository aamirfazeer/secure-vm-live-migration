#!/bin/bash

NAME=$1
CNT=${2:-1}

for i in $(seq 1 $CNT);
do	 
	sudo rm $NAME'_'$i.img
done
