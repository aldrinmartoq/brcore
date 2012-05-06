main: brcore-epoll.o main.o
	brayatan-cc -g -o main brcore-epoll.o main.o

brcore-epoll.o: brcore.h brcore-epoll.m
	brayatan-cc -g -c -o brcore-epoll.o brcore-epoll.m

main.o: main.m brcore.h
	brayatan-cc -g -c -o main.o main.m

clean:
	rm -f *.o main
