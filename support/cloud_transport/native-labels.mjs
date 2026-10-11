// OEM text styling varies in case; package, button role and resource stay exact.
export function exactNativeButton({packageName,resourceId,text}) {
 return {using:'xpath',value:`//*[@package="${packageName}" and @class="android.widget.Button" and @resource-id="${resourceId}" and translate(@text,"ABCDEFGHIJKLMNOPQRSTUVWXYZ","abcdefghijklmnopqrstuvwxyz")="${text.toLowerCase()}" and @clickable="true" and @enabled="true"]`};
}
