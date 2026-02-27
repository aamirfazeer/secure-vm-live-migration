#!/bin/bash

SOURCE=$1
NAME=$2
DESTINATION=${3:-'.'}
CNT=${4:-1}

for i in $(seq 1 $CNT);
do	 
	IMAGE=$DESTINATION/$NAME'_'$i.img
	sudo rsync -av --progress $SOURCE $IMAGE
	sudo chmod 777 $IMAGE
	sudo chown nobody:nogroup $IMAGE 
done
