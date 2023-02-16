#!/bin/bash

if [ -z "$2" ]; then
	echo "Pass projectId and path to Powershell script"
	exit
fi
echo "Will update golden image for project $1 with script $2"
