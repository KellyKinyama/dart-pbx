cat star_zesco_co_zm.crt > certificate_chain.crt

cp star_zesco_co_zm.crt certificate_chain.crt
cat DigiCertCA.crt certificate_chain.crt> certificate_chain.crt

openssl x509 -in mycert.crt -out mycert.pem -outform PEM

openssl x509 -in certificate_chain.crt -out certificate_chain.pem -outform PEM

openssl x509 -in DigiCertCA.crt -out certificate_ca.pem -outform PEM
openssl x509 -in star_zesco_co_zm.crt -out certificate_chain.pem -outform PEM

cp star_zesco_co_zm.key mykey.pem > certificate_chain.pem 

certificate_ca.pem

cat DigiCertGridCA-1.crt.pem

dart compile exe bin/dart_pbx.dart


//////
cat  certificate_chain.crt star_zesco_co_zm.crt> certificate_chain2.crt
