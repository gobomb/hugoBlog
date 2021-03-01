BLOGPATH=`pwd`


cd  $BLOGPATH && hugon --theme=basics --baseUrl="https://gobomb.github.io/"

## update submodule
# git diff --cached --submodule

## add GA
# cp bak/header.html layouts/partials/header.html
