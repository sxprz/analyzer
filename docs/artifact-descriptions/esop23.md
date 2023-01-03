# ESOP '23 Artifact Description

This is the artifact description for our ESOP '23 paper "Clustered Relational Thread-Modular Abstract Interpretation with Local Traces".
<!-- The artifact is available from Zenodo [here](TODO: Update URL). -->

The artifact is a VirtualBox Image based on Ubuntu 22.04.1. The login is `goblint:goblint`.

<!-- If you are reading these instructions on goblint.readthedocs.io, they might have been updated to match the current version of Goblint.
When using the artifact, follow the similar instructions it includes. -->

# Getting Started Guide

- Install VirtualBox (e.g. from [virtualbox.org](https://www.virtualbox.org/))
- Import the VM via `File -> Import Appliance`
- Start the VM and (if prompted) login as `goblint` with password `goblint`
- Navigate to the folder `~/analyzer`. All paths are given relative to it.
- Run the following commands to verify the installation works as intended
    - `./scripts/esop23-kick-tires.sh` (will take ~3min)
        - Internally, this will run a few internal regression tests (you can open the script to see which)
        - After the command has run, there should be some messages `No errors :)` as well as some messages `Excellent: ignored check on ... now passing!`)

# Step-by-Step Instructions

The following are step-by-step instructions to reproduce the experimental results underlying the paper.
Depending on the host machine, the run times will be slightly different from what is reported in the paper,
but they should behave the same way relative to each other.

**Important note: We based our implementation on our previous work on Goblint, but also compare with Goblint in the non-relational setting from our previous SAS paper. This previous version is referred to as "Goblint w/ Interval"**

## Claims in Paragraph "Internal comparison" (p.23)

All these claims derive from Fig. 13 (a) and 13 (b). The data underlying these tables is produced by running:

1. Run the script `../bench/esop23_fig13.rb`. This takes ~25 min (see note below).
2. Open the results HTML `../bench/bench_result/index.html`.

    - The configurations are named the same as in the paper (with the exception that the `Interval` configuration from the paper is named `box` in the table, and `Clusters` is named `cluster12`).
    - As noted in appendix I.1, we had to exclude `ypbind` from the benchmarks, as it spawns a thread from an unknown pointer which the analysis can not handle
    - As dumping the precision information incurs a significant performance penalty, each configuration is run twice: Once to measure runtime and once with
    the post-processing that marshals the internal data structures to disk.



### Notes
* The source code for benchmarks can be found in `../bench/pthread/` and `../bench/svcomp/`.
* Although it takes ~25 min to run all the benchmarks, the script continually updates the results HTML. Therefore it's possible to observe the first results in the partially-filled table without having to wait for the script to finish (if that shows you a blank, try waiting a while and refreshing).


## All other claims in Section 9

All these claims are based on the contents of Table 2. The different sets in this table are reproduced by different scripts.

For all of them:
  - The results table shows for each test the total numbers of asserts and how many could be proven:
      - If all are proven, the cell shows a checkmark
      - If none are proven, the cell shows a cross
      - If only some are proven, the cell shows both numbers

These scripts produces the numbers for all configurations of our tool as well as for "Goblint w/ Intervals" that we are comparing against.
For reproducing the numbers for Duet see below.

### Set "Our"

1. Run the script `../bench/esop23_table2_set_our.rb`. This takes ~3min
2. Open the results HTML `../bench/bench_result/index.html`.


### Set "Goblint"

1. Run the script `../bench/esop23_table2_set_goblint.rb`. This takes ~ XX min
2. Open the results HTML `../bench/bench_result/index.html`.

### Set "Watts"

Note: For a detailed discussion on these benchmarks, see Appendix I.2 of the paper.

1. Run the script `../bench/esop23_table2_set_watts.rb`. This takes ~ XX min
2. Open the results HTML `../bench/bench_result/index.html`.

As opposed to the other scripts, this one also prints run-times as these are needed to also verify Table 4 in the supplementary material.

### Set "Ratcop"

1. Run the script `../bench/esop23_table2_set_goblint.rb`. This takes ~ XX min
2. Open the results HTML `../bench/bench_result/index.html`.

### Reproducing Duet numbers

This artifact ships Duet (at commit 5ea68373bb8c8cff2a9b3a84785b12746e739cee) with a bug fix (courtesy of its original author Zach Kincaid) allowing it to run successfully on some of the benchmarks.
For others, it sill reported a number of reachable asserts that is too low, we only give the instructions to reproduce the successful runs here.
For a detailed discussion see Apppendix I.3.




## Additional Information
### Outline of how the code is structured
Lastly, we give a general outline of how code in the Goblint framework is organized:
The source code is in the directory `./src`, where the subdirectories are structured as follows:

The most relevant directories are:

- `./src/solvers`: Different fix-point solvers that can be used by Goblint (default is TD3)
- `./src/domains`: Various generic abstract domains: Sets, Maps, ...
- `./src/cdomains`: Abstract domains for C programs (e.g. Integers, Addresses, ...)
- `./src/analyses`: Different analyses supported by Goblint
- `./src/framework`: The code of the analysis framework

Other, not directly relevant, directories:

- `./src/extract`: Related to extracting Promela models from C code
- `./src/incremental`: Related to Incremental Analysis
- `./src/spec`: Related to parsing Specifications for an automata-based analysis of liveness properties
- `./src/transform`: Specify transformations to run based on the analysis results
- `./src/util`: Various utility modules
- `./src/witness`: Related to witness generation