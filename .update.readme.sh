#!/bin/bash

cd doc
for item in *.plantuml
do
   #plantuml ${item}
   java -jar ~/.vscode/extensions/jebbs.plantuml-*/plantuml.jar ${item}
   if [ $? -eq 0 ]
   then
      git add ${item}
      git add ${item%.*}.png
   fi
done
