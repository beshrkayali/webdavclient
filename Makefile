.RECIPEPREFIX +=

.PHONY: format
format:
  nimfmt -i src/webdavclient.nim


.PHONY: develop
develop:
  nimble develop --verbose


.PHONY: install
install:
  nimble install -y
