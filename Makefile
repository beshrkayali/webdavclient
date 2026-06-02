.PHONY: format
format:
	nimfmt -i src/webdavclient.nim tests/test_webdav.nim tests/test_parsing.nim


.PHONY: develop
develop:
	nimble develop --verbose


.PHONY: install
install:
	nimble install -y


.PHONY: test
test:
	nimble test


.PHONY: docker-test
docker-test:
	docker compose -f tests/docker-compose.test.yml -p nim-webdavclient-test up --exit-code-from sut --force-recreate
