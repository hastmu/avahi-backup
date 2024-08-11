#!/bin/bash

cd doc
for item in *.plantuml
do
   plantuml ${item}
done
