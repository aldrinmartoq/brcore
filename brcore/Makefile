main: brcore.o main.o
	brayatan-cc -g -o main brcore.o main.o

brcore.o: brcore.h brcore.m
	brayatan-cc -g -c -o brcore.o brcore.m

main.o: main.m brcore.h
	brayatan-cc -g -c -o main.o main.m

clean:
	rm *.o main
