### Running the autograder yourself from the "plate" machines

Move the contents of this directory to where you currently have your work. The directory structure must look as follows to run:

- dtw_serial
- dtw_parallel.c
- config.json
- autograder.sh
- grade_wrapper.py
- tests
   - testin_0.txt
   - testout_0.txt
   - testin_1.txt
   - testout_1.txt
   - ...


Use `python3 grade_wrapper.py` to run the autograder from the plate machines. This will output 

(1) Your projected grade (if only the given unit tests were used).
(2) The rubric for that grade.
(3) The logs of each variation of (threads, test)

The `autograder.sh` file will output logs dictating whether or not tests are passing. 
The `grade_wrapper.py` file will read these logs & assign scores according to the rubric evaluation.
The `config.json` dictates which unit tests indicate speedups & which unit tests should be visible. This must match the set of tests in the `tests` directory.

We will run this exact program on our end, but with a series of additional, hidden tests and slight modifications to the config.json file for handling hidden unit test messages.