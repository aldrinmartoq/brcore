main: brcore.o main.o
	brayatan-cc -Os -o main brcore.o main.o

brcore.o: brcore.h brcore.m
	brayatan-cc -Os -c -o brcore.o brcore.m

main.o: main.m brcore.h
	brayatan-cc -Os -c -o main.o main.m

clean:
	rm *.o main
