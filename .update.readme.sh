#!/bin/bash

cd doc
for item in *.plantuml
do
   #plantuml ${item}
   echo "- rendering...${item}"
   java -jar ~/.vscode/extensions/jebbs.plantuml-*/plantuml.jar ${item}
   if [ $? -eq 0 ]
   then
      echo "+ adding"
      git add ${item}
      git add ${item%.*}.png
   fi
done
