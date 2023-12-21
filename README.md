# Spinda Counter
A small program in Zig (0.11.0) to estimate the number of *visually* distinct Spinda sprites in Pokémon Emerald.

Result: approx. 2,555,000,000 ± 50,000 distinct Spindas

## Build
1. If you haven't already, install [Zig 0.11.0](https://ziglang.org/download/) and add the directory to your PATH.
2. `zig build run`

This project has no other dependencies.

## Explanation
Spindas in most Pokémon games have spots in a random pattern on its head. In Pokémon Emerald, this is determined by its personality value (PV), a pseudo-random 32-bit integer that determines the majority of a Pokémon's individual characteristics. There are four Spinda spots, each equipped with a default position that is offset by some amount (anywhere between -8 to +7 pixels on either axis). 

A naive estimate of the number of unique Spindas would be the number of possible personality values, which would be 4,294,967,296 (2^32). However, that doesn't account for differing PVs that correspond to identical sprites in practice. The purpose of this program is to obtain a more accurate estimate for the number of distinct Spindas.

## Method
This program performs a brute forch search over all 4,294,967,296 personality values by splitting the work across 430 threads. Each thread generates up to 10,000,000 Spindas, creates a 32-bit hash from the resultant sprite and records it in a bitset. Bitset writes are atomic for thread safety. Once all threads are complete, the result is found by counting the number of set bits.

The reason this provides only an *estimate* is because a 32-bit hash of sprites derived from 32-bit personality values has a decent chance of encountering hash collisions. A larger hash size to solve this would require a significantly larger bitset, which becomes quickly intractable. As a workaround, you can experiment with varying hash seeds.

Keep in mind this method is computationally expensive. On my laptop it takes about 20 minutes from start to end and gets the fan going quite a bit.

## References
- [Decompilation of Pokémon Emerald in C](https://github.com/pret/pokeemerald/blob/6385f0426d0ad48d46b63a433b38170e94dca0af/src/pokemon.c#L5686) for the pattern algorithm and spot sprites
- [Bulbapedia](https://bulbapedia.bulbagarden.net/wiki/Spinda_(Pok%C3%A9mon)) for example patterns