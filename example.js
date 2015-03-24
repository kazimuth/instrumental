function factorial(n) {
    var acc = 1;
    for (var i = 2; i <= n; i++) {
        acc *= i;
    }
    return acc
}

console.log(factorial(5));

