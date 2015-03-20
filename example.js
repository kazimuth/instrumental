fibbonacci = function(i) {
    if (i < 2) {
        return 1;
    } else {
        var minus1 = fibbonacci(i-1);
        var minus2 = fibbonacci(i-2);
        return minus1 + minus2;
    }
}

fib5 = fibbonacci(5);
console.log(fib5);
