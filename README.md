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

## Configuration

The plugin configuration is an HTML text area in which a _YAML_ structure is pasted. The available options
are maintained on this document. Example:

```
targets:
  KOHA_1:
    ZID: 6   # ID of remote koha instance as configured as a z3950 target
    ILSDI: https://koha-instance-1.com/cgi-bin/koha/ilsdi.pl
    user: remote_koha_ill_username
    password: remote_koha_ill_userpassword
  KOHA_2:
    ZID: 7   # ID of remote koha instance as configured as a z3950 target
    ILSDI: https://koha-instance-2.com/cgi-bin/koha/ilsdi.pl
    user: remote_koha_ill_username
    password: remote_koha_ill_userpassword
framework: ILL
```
