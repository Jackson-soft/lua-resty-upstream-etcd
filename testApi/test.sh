#!/bin/bash

./wrk -t12 -c400 -d30s http://127.0.0.1/test-api

./wrk -t12 -c400 -d30s http://127.0.0.1:8080/test-etcd
