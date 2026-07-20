# Speak-IP-Address-for-ASL3
Make your AllStarLink Node speak it's Local IP address on reboot
## Installation Instructions

First it's alway good to start at the profile root directory
```
cd ~
```

Then we need to download the installation script file
```
sudo wget https://raw.githubusercontent.com/KD5FMU/Speak-IP-Address-for-ASL3/refs/heads/main/install-speakip-v1.0.9.sh
```
Then we need to make it executable
```
sudo chmod +x install-speakip-v1.0.9.sh
```
Then execute the installer script
```
sudo ./install-speakip-v1.0.9.sh
```
Once you run the script installer it will ask for your Node number for the node it is being installed on. Once the script installer is finished it will ask if you want to play the local IP and you can answer yes or no
<br>
Once fininshed every time you reboot your node will play your local IP address over RF. And now you can play the local IP or the Public IP address at will with DTMF commands, AND you will have the ability to reboot or shutdown your node with two different DTMF commands listed here:<br>
<br>
  *890 = Shutdown AllStar Node<br>
  *891 = Reboot AllStar Node<br>
  *892 = Speak Local IP address<br>
  *893 = Speak Public IP address<br>

<br>
I hope you get some use from this setup
73 and Ham On Y'all!!

