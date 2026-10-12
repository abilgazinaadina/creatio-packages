ARG BASE=localhost:5002/creatio-base:8.3.2

FROM ${BASE}

COPY ./out/packages/ /app/Terrasoft.Configuration/Pkg/