ARG BASE=localhost:5002/creatio-base:8.3.2

FROM ${BASE}

COPY ./out/packages/ /app/Terrasoft.Configuration/Pkg/

# Keep generated assemblies, metadata and static content from the same compile.
RUN rm -rf /app/conf
COPY ./out/conf/ /app/conf/
