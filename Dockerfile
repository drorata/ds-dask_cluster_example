FROM continuumio/anaconda3
RUN mkdir /project
WORKDIR /project
COPY *.py /project/
RUN pip install dask_searchcv
