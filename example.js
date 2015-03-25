function iterativeFactorial(n) {
    var acc = 1;
    for (var i = 2; i <= n; i++) {
        acc *= i;
    }
    return acc
}

function recursiveFactorial(n) {
    if (n < 2) return 1;
    else return n * recursiveFactorial(n-1);
}

console.log("Same results? " + (iterativeFactorial(5) == recursiveFactorial(5)));

