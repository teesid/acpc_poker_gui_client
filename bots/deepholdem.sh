#!/bin/bash

ssh -t -p 16605 -R "$2:localhost:$2" root@ssh4.vast.ai /root/work/start-deepstack.sh "$2"
