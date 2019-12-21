function postData(url, data) {
    return fetch(url, {
        body: JSON.stringify(data),
        headers: {
            "content-type": "application/json",
        },
        method: "POST",
    })
        .then(resp => resp.json())
        .then(mData => {
            if (mData.code != 0) {
                let message = mData.errMsg.length == 0 ? "not found element..." : mData.errMsg;
                alert("error: " + message);
            } else {
                return mData.data;
            }
        });
}

// 测试
var host = "http://127.0.0.1:8080";

// 日常环境
//var host = "https://nginx-upstream-middleware-daily.app.2dfire-daily.com";

// 预发环境
// var host = "https://nginx-upstream-pre-middleware.app.2dfire.com";

// 正式环境
// var host = "https://nginx-upstream-middleware.app.2dfire.com";

function creatTable(data) {
    console.log(data);
    var t = document.getElementById("myTable");
    t.innerHTML = "";
    var table = document.createElement("table");
    table.id = "myTable";
    table.setAttribute("border", "1");
    // table.setAttribute("width", "600");

    var myKey = ["key", "value"];
    for (var m = 0; m < myKey.length; m++) {
        var tr = document.createElement("tr");
        var th = document.createElement("th");
        th.innerHTML = myKey[m];
        tr.appendChild(th);
        table.appendChild(th);
    }

    var nList = 2;

    for (var mm in data) {
        var tr2 = document.createElement("tr");
        for (var j = 0; j < nList; j++) {
            var td = document.createElement("td");
            if (j % 2 == 0) {
                td.innerHTML = mm;
            } else {
                td.innerHTML = data[mm];
            }
            tr2.appendChild(td);
        }
        table.appendChild(tr2);
    }
    document.getElementById("myTable").appendChild(table);
}

function onGet() {
    var sKey = document.getElementById("getKey").value;
    var bPrefix = document.getElementById("getPrefix").checked;
    console.log(sKey, bPrefix);

    if (sKey == "") {
        sKey = "upstream";
    }

    var url = host + "/api/get_upstream";
    var data = {
        key: sKey,
        prefix: bPrefix,
    };
    postData(url, data).then(out => creatTable(out));
}

function onMod() {
    var sKey = document.getElementById("modKey").value;
    var sValue = document.getElementById("modValue").value;
    console.log(sKey, sValue);
    if (sKey == "") {
        alert("输入要修改的值");
    }
    var url = host + "/api/put_upstream";
    var data = {
        key: sKey,
        value: sValue,
    };
    postData(url, data);
}

function onDel() {
    var sKey = document.getElementById("delKey").value;
    var bPrefix = document.getElementById("delPrefix").checked;
    console.log(sKey, bPrefix);
    if (sKey == "") {
        alert("输入要删除的值");
        return;
    }
    var url = host + "/api/del_upstream";
    var data = {
        key: sKey,
        prefix: bPrefix,
    };
    postData(url, data);
}
