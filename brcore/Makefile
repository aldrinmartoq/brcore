CFLAGS=-g -O2

main-kqueue: brcore-kqueue.o main.o http_parser.o
	brayatan-cc $(CFLAGS) -o main-kqueue brcore-kqueue.o main.o http_parser.o

main: brcore-epoll.o main.o http_parser.o
	brayatan-cc $(CFLAGS) -o main brcore-epoll.o main.o http_parser.o

brcore-kqueue.o: brcore.h brcore-kqueue.m
	brayatan-cc $(CFLAGS) -c -o brcore-kqueue.o brcore-kqueue.m

brcore-epoll.o: brcore.h brcore-epoll.m
	brayatan-cc $(CFLAGS) -c -o brcore-epoll.o brcore-epoll.m

main.o: main.m brcore.h
	brayatan-cc $(CFLAGS) -c -o main.o main.m

clean:
	rm -f *.o main
