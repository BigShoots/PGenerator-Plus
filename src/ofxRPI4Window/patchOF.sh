#!/bin/bash

# Use to apply patches to openFrameworks
# Patching script by daandelange.com

ACTION="";
INTERACTIVE=1;

if [ "$INTERACTIVE" -eq 1 ]; then
	echo "Hello,";
	echo "This script lets you modify your openFrameworks installation.";
	echo "	1. Enable ofxRPI4 windows";
	echo "	2. Disable ofxRPI4 windows (reverts to default oF installation)";
	printf "Your choice: " && read -r ANSWER
	
	if [[ "$ANSWER" -eq "1" ]]; then
		ACTION="enable";
	elif [[ "$ANSWER" -eq "2" ]]; then
		ACTION="revert";
	else
		echo "Unvalid option. Quitting now.";
		exit 0;
	fi
fi

if [[ "$ACTION" = "enable" ]]; then
	echo "Patching OF for ofxRPI4Window support.";

	echo "Commenting out USE_GLFW_WINDOW...";
	sed -i 's/^	USE_GLFW_WINDOW = 1/#	USE_GLFW_WINDOW = 1/g' ../../libs/openFrameworksCompiled/project/linuxarmv6l/config.linuxarmv6l.default.mk

	echo "Disabling the native ofSetupOpenGL...";
	# These don't work well
	#sed -i 's/^	void ofSetupOpenGL/\/*	void ofSetupOpenGL/g' ../../libs/openFrameworks/app/ofAppRunner.cpp
	#sed -i 's/windowPtr->setup\(settings\);\n\t}/windowPtr->setup\(settings\);\n\t}*\//g' ../../libs/openFrameworks/app/ofAppRunner.cpp

	GLSETUP_LINE_START=`awk '/void ofSetupOpenGL/{ print NR; exit }' ../../libs/openFrameworks/app/ofAppRunner.cpp`;
	if [ -z "$GLSETUP_LINE_START" ]; then
		echo "Error, could not find the ofSetupOpenGL section... please proceed manually.";
	else
		GLSETUP_LINE_END=$(awk "NR>$GLSETUP_LINE_START && /	\}/{print NR; exit }" ../../libs/openFrameworks/app/ofAppRunner.cpp);
		if [ -z "$GLSETUP_LINE_END" ]; then
			echo "Weird, could not find closing }. Using static offset of 7 lines.";
			GLSETUP_LINE_END=$(expr $GLSETUP_LINE_START + 7);
		fi
		echo "Found ofSetupOpenGL on lines : $GLSETUP_LINE_START -> $GLSETUP_LINE_END (commenting them now)";
		sed -i "$(echo $GLSETUP_LINE_START)s/.*/\/*	void ofSetupOpenGL\(shared_ptr\<ofAppGLFWWindow\> windowPtr, int w, int h, ofWindowMode screenMode\)\{/" ../../libs/openFrameworks/app/ofAppRunner.cpp;
		sed -i "$(echo $GLSETUP_LINE_END)s/.*/	\}*\//" ../../libs/openFrameworks/app/ofAppRunner.cpp;
		
		echo "Successfully patched :) . Exiting now.";
	fi
	
	exit 0;
elif [[ "$ACTION" = "revert" ]]; then
	echo "Reverting back OF to its original state...";

	echo "Uncommenting USE_GLFW_WINDOW...";
	sed -i 's/#	USE_GLFW_WINDOW = 1/	USE_GLFW_WINDOW = 1/g' ../../libs/openFrameworksCompiled/project/linuxarmv6l/config.linuxarmv6l.default.mk

	echo "Enabling the native ofSetupOpenGL...";
	GLSETUP_LINE_START=`awk '/void ofSetupOpenGL/{ print NR; exit }' ../../libs/openFrameworks/app/ofAppRunner.cpp`;
	if [ -z "$GLSETUP_LINE_START" ]; then
		echo "Error, could not find the ofSetupOpenGL section... please proceed manually.";
	else
		#GLSETUP_LINE_END=`awk '/	\}/{ if(NR>31){print NR; exit }else{}}' ../../libs/openFrameworks/app/ofAppRunner.cpp`;
		GLSETUP_LINE_END=$(awk "NR>$GLSETUP_LINE_START && /	\}/{print NR; exit }" ../../libs/openFrameworks/app/ofAppRunner.cpp);
		if [ -z "$GLSETUP_LINE_END" ]; then
			echo "Weird, could not find closing }. Using static offset of 7 lines.";
			GLSETUP_LINE_END=$(expr $GLSETUP_LINE_START + 7);
		fi
		
		echo "Found ofSetupOpenGL on lines : $GLSETUP_LINE_START -> $GLSETUP_LINE_END (uncommenting them now)";
		sed -i "$(echo $GLSETUP_LINE_START)s/.*/	void ofSetupOpenGL\(shared_ptr\<ofAppGLFWWindow\> windowPtr, int w, int h, ofWindowMode screenMode\)\{/" ../../libs/openFrameworks/app/ofAppRunner.cpp;
		sed -i "$(echo $GLSETUP_LINE_END)s/.*/	\}/" ../../libs/openFrameworks/app/ofAppRunner.cpp;
		
		echo "Successfully reverted oF to factory defaults :) . Exiting now.";
	fi

	exit 0;
else
	echo "Nothing to be done. Exiting now";
	exit 1;
fi

