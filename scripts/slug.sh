#!/bin/sh

slug() {
    echo "$1" \
      | tr '[:upper:]' '[:lower:]' \
      | sed 's#[^a-z0-9]#-#g; s#-\+#-#g; s#^-##' \
      | cut -c1-30 \
      | sed 's#-$##'
}

slug "$1"