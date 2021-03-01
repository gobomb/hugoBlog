BLOGPATH=`pwd`


cd  $BLOGPATH && hugo --theme=basics --baseUrl="https://gobomb.github.io/"

## update submodule
# git diff --cached --submodule

## add GA
# cp bak/header.html layouts/partials/header.html

## save version of hugo
# echo "#" `hugo version` >> generate.sh
# hugo v0.81.0-59D15C97 darwin/amd64 BuildDate=2021-02-19T17:07:12Z VendorInfo=gohugoio
