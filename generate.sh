BLOGPATH=`pwd`


cd  $BLOGPATH && hugo --theme=basics --baseUrl="https://gobomb.github.io/"

## update submodule
# git diff --cached --submodule

## add GA
# cp header.html.bak themes/basics/layouts/partials/header.html
