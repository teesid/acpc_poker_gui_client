FROM ruby:2.6.3-stretch

ENV LC_ALL C.UTF-8
ENV LANG C.UTF-8

COPY . /code
WORKDIR /code

RUN bundle install
RUN wget https://fastdl.mongodb.org/linux/mongodb-linux-x86_64-debian92-4.2.0.tgz && \
    tar xzf mongodb-linux-x86_64-debian92-4.2.0.tgz && \
    mkdir vendor && \
    mv mongodb-linux-x86_64-debian92-4.2.0 vendor/mongoDB && \
    rm mongodb-linux-x86_64-debian92-4.2.0.tgz && \
    mkdir -p /data/db
RUN apt-get update -qq && \
    apt-get install -y nodejs vim && \
    bundle exec rake install:dev

EXPOSE 3000
CMD ["bash", "-c", "rm -fr /code/tmp; /code/script/start_daemons; bundle exec rails s"]
