# Koha Interlibrary Loans Koha backend

This backend provides the ability to create Interlibrary Loan requests by searching other Koha instances.

## Getting Started

The version of the backend you require depends on the version of Koha you are using:
* 17.11 - Use the 17.11 branch if you are using this version of Koha
* 18.05 - Use the 18.05 branch if you are using this version of Koha
* master - Use this master branch for 18.11 and upwards

## Installing

* Create a directory in `Koha` called `Illbackends`, so you will end up with `Koha/Illbackends`
* Clone the repository into this directory, so you will end up with `Koha/Illbackends/koha-ill-koha`
* In the `koha-ill-koha` directory switch to the branch you wish to use
* Rename the `koha-ill-koha` directory to `Koha`
* Activate ILL by enabling the `ILLModule` system preference

# Caveats

* The current implimentation requires some inline configuration to be done in the Base.pm file. These will be moved into a config screen or file in due course.
