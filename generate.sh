BLOGPATH=`pwd`


cd  $BLOGPATH && hugo --theme=even --baseUrl="https://gobomb.github.io/"

# update submodule
git diff --cached --submodule

