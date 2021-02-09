/**
 * This file is used to validate iOS test-cases. It is ran using the Xcode
 * project in titanium_mobile/iphone/iphone/Titanium.xcodeproj.
 *
 * Change the below code to fit your use-case. By default, it included a button
 * to trigger a log that is displayed in the Xcode console.
 */

const win = new Ti.UI.Window({
	backgroundColor: '#fff'
});

const btn = new Ti.UI.Button({
	title: 'Trigger'
});

btn.addEventListener('click', () => {
	Ti.API.info(L('hello_world'));
});

win.add(btn);
win.open();
